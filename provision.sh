#!/usr/bin/env bash
# =============================================================================
# provision.sh – Idempotent Infrastructure Provisioning for Shopizer
#
# Implements "Infrastructure as Code" for the full Shopizer local stack using
# Colima as the container runtime on macOS.  Safe to run multiple times –
# each step is a no-op when the desired state already exists.
#
# What this script does (in order):
#   1. Validate OS and detect CPU architecture
#   2. Install / update all tool prerequisites via infra/Brewfile
#   3. Apply infra/colima.yaml to the named "shopizer" Colima profile
#   4. Start the Colima VM (or reconcile if CPU/memory changed)
#   5. Configure the Docker context to use the Colima VM
#   6. Initialise deployment/.env from .env.example (if absent)
#   7. Check that the required Docker images are present
#   8. Pull images from GitHub Actions artifacts (deploy-local.sh) - optional
#   9. Start the full stack with docker compose
#  10. Wait for the backend health endpoint and print service URLs
#
# Prerequisites (installed automatically if missing):
#   - macOS 12+, Homebrew
#   - colima, docker, docker-compose, gh, jq, wget
#
# Usage:
#   ./provision.sh [OPTIONS]
#
# Options:
#   --skip-brew       Skip Homebrew package installation (tools already exist)
#   --skip-images     Skip GitHub artifact pull (use already-loaded images)
#   --only-infra      Stop after Colima is running (do not start app containers)
#   --reconfigure     Force Colima VM stop/restart to apply updated colima.yaml
#   -h, --help        Show this help message
#
# Examples:
#   ./provision.sh                       # Full first-time setup
#   ./provision.sh --skip-brew           # Tools already installed
#   ./provision.sh --skip-images         # Images already loaded locally
#   ./provision.sh --only-infra          # Provision VM only, no app deployment
#   ./provision.sh --reconfigure         # Apply updated colima.yaml and restart
# =============================================================================
set -euo pipefail

# ── Script locations ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/infra"
DEPLOYMENT_DIR="${SCRIPT_DIR}/deployment"
COLIMA_PROFILE="shopizer"
COLIMA_CONFIG_SOURCE="${INFRA_DIR}/colima.yaml"
COLIMA_CONFIG_TARGET="${HOME}/.colima/${COLIMA_PROFILE}/colima.yaml"
DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
STEP_N=0

step()    { STEP_N=$((STEP_N+1));
            echo -e "\n${BLUE}${BOLD}[Step ${STEP_N}]${RESET} ${BOLD}$*${RESET}"; }
info()    { echo -e "  ${CYAN}→${RESET}  $*"; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "\n  ${RED}✖  ERROR: $*${RESET}\n" >&2; exit 1; }
hr()      { echo -e "  ${BOLD}────────────────────────────────────────────${RESET}"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
SKIP_BREW=false
SKIP_IMAGES=false
ONLY_INFRA=false
RECONFIGURE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-brew)    SKIP_BREW=true;    shift ;;
    --skip-images)  SKIP_IMAGES=true;  shift ;;
    --only-infra)   ONLY_INFRA=true;   shift ;;
    --reconfigure)  RECONFIGURE=true;  shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Shopizer  ·  IaC Provisioner  ·  Colima     ║${RESET}"
echo -e "${BOLD}╚════════════════════════════════════════════════╝${RESET}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 – OS & Architecture validation
# ═════════════════════════════════════════════════════════════════════════════
step "Validating environment"

OS="$(uname -s)"
if [[ "$OS" != "Darwin" ]]; then
  error "This script targets macOS. Detected OS: ${OS}"
fi

ARCH="$(uname -m)"
ok "macOS detected (arch: ${ARCH})"

# Warn if not on Ventura+ (where vmType=vz / virtiofs would give better perf)
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MACOS_MAJOR" -ge 13 ]]; then
  warn "macOS 13+ detected. Consider enabling vmType=vz + mountType=virtiofs in"
  warn "infra/colima.yaml for faster VM I/O, then re-run with --reconfigure."
fi

# Check Homebrew is available
if ! command -v brew &>/dev/null; then
  error "Homebrew not found. Install it first:\n  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi
ok "Homebrew found: $(brew --version | head -1)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 – Install prerequisites via Brewfile
# ═════════════════════════════════════════════════════════════════════════════
step "Installing tool prerequisites (infra/Brewfile)"

if [[ "$SKIP_BREW" == "true" ]]; then
  warn "--skip-brew set; assuming all tools are present"
else
  info "Running: brew bundle --file ${INFRA_DIR}/Brewfile"
  brew bundle --file "${INFRA_DIR}/Brewfile" 2>&1 \
    | sed 's/^/    /'
  ok "All Brewfile packages satisfied"
fi

# Verify critical binaries are reachable
for CMD in colima docker gh jq qemu-img; do
  command -v "$CMD" &>/dev/null || error "${CMD} not found after Brewfile install. Check PATH."
  ok "${CMD} $(${CMD} version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1)"
done

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 – Apply Colima VM specification
# ═════════════════════════════════════════════════════════════════════════════
step "Applying Colima VM specification (infra/colima.yaml → profile: ${COLIMA_PROFILE})"

# Create the profile directory if it doesn't exist
mkdir -p "${HOME}/.colima/${COLIMA_PROFILE}"

CONFIG_CHANGED=false
if [[ -f "$COLIMA_CONFIG_TARGET" ]]; then
  if ! diff -q "$COLIMA_CONFIG_SOURCE" "$COLIMA_CONFIG_TARGET" &>/dev/null; then
    info "colima.yaml has changed since last apply"
    CONFIG_CHANGED=true
  else
    ok "colima.yaml is already up-to-date"
  fi
else
  info "First-time apply – writing colima.yaml to profile directory"
  CONFIG_CHANGED=true
fi

if [[ "$CONFIG_CHANGED" == "true" ]]; then
  cp "$COLIMA_CONFIG_SOURCE" "$COLIMA_CONFIG_TARGET"
  ok "Wrote ${COLIMA_CONFIG_TARGET}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 – Start / reconcile the Colima VM
# ═════════════════════════════════════════════════════════════════════════════
step "Starting Colima VM (profile: ${COLIMA_PROFILE})"

COLIMA_STATUS="$(colima status "${COLIMA_PROFILE}" 2>&1 || true)"

if echo "$COLIMA_STATUS" | grep -q "^colima \[${COLIMA_PROFILE}\] is running"; then
  if [[ "$CONFIG_CHANGED" == "true" && "$RECONFIGURE" == "true" ]]; then
    warn "Config changed and --reconfigure requested; stopping VM to apply new spec"
    colima stop "${COLIMA_PROFILE}"
    info "VM stopped. Restarting with updated specification…"
    colima start "${COLIMA_PROFILE}"
    ok "Colima profile '${COLIMA_PROFILE}' restarted with updated config"
  elif [[ "$CONFIG_CHANGED" == "true" ]]; then
    warn "infra/colima.yaml was updated but the VM is already running."
    warn "CPU/memory/disk changes require a restart. Run with --reconfigure to apply."
    warn "Continuing with the currently running VM."
    ok "Colima profile '${COLIMA_PROFILE}' is running (not restarted)"
  else
    ok "Colima profile '${COLIMA_PROFILE}' is already running"
  fi
else
  info "Starting Colima profile '${COLIMA_PROFILE}'…"
  info "(This takes ~30-60 s on first start while downloading the VM image)"

  # Read specs from colima.yaml for the start command (fallback if profile
  # config hasn't been picked up yet by an older Colima version)
  CPU="$(grep '^cpu:'    "$COLIMA_CONFIG_SOURCE" | awk '{print $2}')"
  MEM="$(grep '^memory:' "$COLIMA_CONFIG_SOURCE" | awk '{print $2}')"
  DSK="$(grep '^disk:'   "$COLIMA_CONFIG_SOURCE" | awk '{print $2}')"

  colima start "${COLIMA_PROFILE}" \
    --cpu    "${CPU:-2}" \
    --memory "${MEM:-4}" \
    --disk   "${DSK:-60}"

  ok "Colima profile '${COLIMA_PROFILE}' started"
fi

# Confirm Docker is reachable through the new VM
ok "Colima VM info:"
colima list | grep -E "^(NAME|${COLIMA_PROFILE})" | sed 's/^/    /'

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 – Configure Docker context
# ═════════════════════════════════════════════════════════════════════════════
step "Configuring Docker context (${DOCKER_CONTEXT})"

# colima start --name shopizer creates context "colima-shopizer"
CURRENT_CONTEXT="$(docker context show 2>/dev/null || echo '')"
if [[ "$CURRENT_CONTEXT" == "$DOCKER_CONTEXT" ]]; then
  ok "Docker context is already set to '${DOCKER_CONTEXT}'"
else
  # Verify the context exists before switching
  if docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx "$DOCKER_CONTEXT"; then
    docker context use "$DOCKER_CONTEXT"
    ok "Switched Docker context to '${DOCKER_CONTEXT}'"
  else
    warn "Expected context '${DOCKER_CONTEXT}' not found."
    warn "Available contexts:"
    docker context ls --format '  {{.Name}}  {{.DockerEndpoint}}' | sed 's/^/    /'
    error "Cannot proceed without a valid Docker context. Make sure Colima started correctly."
  fi
fi

# Final connectivity check
docker info &>/dev/null || error "Docker daemon is not responding through context '${DOCKER_CONTEXT}'"
ok "Docker daemon reachable (context: $(docker context show))"

# Bail out here when --only-infra is set
if [[ "$ONLY_INFRA" == "true" ]]; then
  echo ""
  ok "Infrastructure provisioning complete (--only-infra; app containers not started)"
  echo ""
  echo -e "  ${BOLD}Colima profile${RESET}  : ${COLIMA_PROFILE}"
  echo -e "  ${BOLD}Docker context${RESET}  : ${DOCKER_CONTEXT}"
  echo -e ""
  echo -e "  To start the application stack:"
  echo -e "    cd deployment && ./deploy-local.sh --skip-pull"
  echo ""
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 – Initialise deployment/.env
# ═════════════════════════════════════════════════════════════════════════════
step "Initialising deployment environment file"

ENV_FILE="${DEPLOYMENT_DIR}/.env"
ENV_EXAMPLE="${DEPLOYMENT_DIR}/.env.example"

if [[ -f "$ENV_FILE" ]]; then
  ok ".env already exists – leaving untouched"
  info "(Edit ${ENV_FILE} to change image tags, ports, or credentials)"
else
  if [[ ! -f "$ENV_EXAMPLE" ]]; then
    error ".env.example not found at ${ENV_EXAMPLE}"
  fi
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  ok "Created ${ENV_FILE} from .env.example"
  warn "Please review ${ENV_FILE} and set:"
  warn "  MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD (recommended), GITHUB_REPO_BACKEND, GITHUB_REPO_FRONTEND"
fi

# ── Source the .env so we know configured image tags ─────────────────────────
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

IMAGE_TAG_BACKEND="${IMAGE_TAG_BACKEND:-ci-latest}"
IMAGE_TAG_ADMIN="${IMAGE_TAG_ADMIN:-ci-latest}"
IMAGE_TAG_SHOP="${IMAGE_TAG_SHOP:-ci-latest}"

info "Configured image tags:"
info "  Backend  : shopizer:${IMAGE_TAG_BACKEND}"
info "  Admin    : shopizer-admin:${IMAGE_TAG_ADMIN}"
info "  Shop     : shopizer-shop-reactjs:${IMAGE_TAG_SHOP}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 – Verify Docker images are present
# ═════════════════════════════════════════════════════════════════════════════
step "Verifying Docker images"

check_image() {
  local IMAGE="$1" TAG="$2"
  if docker image inspect "${IMAGE}:${TAG}" &>/dev/null; then
    ok "${IMAGE}:${TAG} is present"
    return 0
  else
    warn "${IMAGE}:${TAG} is NOT present in the local daemon"
    return 1
  fi
}

BACKEND_MISSING=false
ADMIN_MISSING=false
SHOP_MISSING=false

check_image "shopizer"              "$IMAGE_TAG_BACKEND" || BACKEND_MISSING=true
check_image "shopizer-admin"        "$IMAGE_TAG_ADMIN"   || ADMIN_MISSING=true
check_image "shopizer-shop-reactjs" "$IMAGE_TAG_SHOP"    || SHOP_MISSING=true

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 – Pull images from GitHub (if missing and not skipped)
# ═════════════════════════════════════════════════════════════════════════════
step "Pulling Docker images from GitHub Actions artifacts"

if [[ "$SKIP_IMAGES" == "true" ]]; then
  warn "--skip-images set; skipping artifact download"
  if [[ "$BACKEND_MISSING" == "true" || "$ADMIN_MISSING" == "true" || "$SHOP_MISSING" == "true" ]]; then
    warn "One or more required images are missing.  The stack may not start."
    warn "Build images locally with the build-image-from-ci.sh scripts, or"
    warn "run deploy-local.sh to download from GitHub artifacts."
  fi
else
  if [[ "$BACKEND_MISSING" == "false" && "$ADMIN_MISSING" == "false" && "$SHOP_MISSING" == "false" ]]; then
    ok "All required images already loaded – skipping artifact pull"
  else
    info "Delegating image pull to deployment/deploy-local.sh --skip-pull=false"
    # deploy-local.sh already handles incremental pull + docker load
    DEPLOY_ARGS=()
    [[ "$BACKEND_MISSING" == "false" && "$ADMIN_MISSING" == "false" && "$SHOP_MISSING" == "false" ]] && DEPLOY_ARGS+=(--skip-pull)

    # Run deploy-local.sh only for the image download step, not compose up
    # We pass --skip-pull selectively via a subshell env override trick:
    (
      set -euo pipefail
      cd "${DEPLOYMENT_DIR}"
      # Temporarily override SKIP_PULL for the subshell
      ./deploy-local.sh "${DEPLOY_ARGS[@]}" --only-backend 2>&1 | sed 's/^/    /'
    ) || warn "deploy-local.sh returned non-zero; images may still be missing"

    # Re-check after pull
    ok "Re-checking images after pull:"
    check_image "shopizer"              "$IMAGE_TAG_BACKEND" || true
    check_image "shopizer-admin"        "$IMAGE_TAG_ADMIN"   || true
    check_image "shopizer-shop-reactjs" "$IMAGE_TAG_SHOP"    || true
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 9 – Start / reconcile the application stack
# ═════════════════════════════════════════════════════════════════════════════
step "Starting application stack (docker compose)"

cd "${DEPLOYMENT_DIR}"

# Force re-creation only for services whose image has been updated
docker compose up -d --remove-orphans

ok "docker compose up complete"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 10 – Wait for backend health and print summary
# ═════════════════════════════════════════════════════════════════════════════
step "Waiting for shopizer-backend to become healthy"

TIMEOUT_S=180
ELAPSED=0
INTERVAL=5
HEALTH="unknown"
BACKEND_HEALTHY=false

printf "  Waiting"
while [[ $ELAPSED -lt $TIMEOUT_S ]]; do
  HEALTH="$(docker inspect --format='{{.State.Health.Status}}' shopizer-backend 2>/dev/null \
            || echo 'not_found')"
  if [[ "$HEALTH" == "healthy" ]]; then
    BACKEND_HEALTHY=true
    break
  fi
  printf "."
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

if [[ "$BACKEND_HEALTHY" == "true" ]]; then
  ok "Backend is healthy (waited ${ELAPSED}s)"
else
  warn "Backend health status after ${TIMEOUT_S}s: ${HEALTH}"
  warn "Showing last 40 log lines from shopizer-backend:"
  docker logs --tail 40 shopizer-backend 2>&1 | sed 's/^/    /'
  warn "Stack may still come up; check logs with:"
  warn "  docker compose -f ${DEPLOYMENT_DIR}/docker-compose.yml logs -f"
fi

# ── Print service URLs ────────────────────────────────────────────────────────
ADMIN_PORT="${ADMIN_PORT:-8081}"
SHOP_PORT="${SHOP_PORT:-8082}"

echo ""
hr
echo ""
echo -e "  ${GREEN}${BOLD}Shopizer is running on Colima (profile: ${COLIMA_PROFILE})${RESET}"
echo ""
echo -e "  ${BOLD}Service${RESET}                ${BOLD}URL${RESET}"
echo -e "  ─────────────────────  ─────────────────────────────────────────────"
echo -e "  API Backend (Swagger)  http://localhost:8080/swagger-ui/index.html"
echo -e "  API Health             http://localhost:8080/actuator/health"
echo -e "  Admin UI (Angular)     http://localhost:${ADMIN_PORT}"
echo -e "  React Shop             http://localhost:${SHOP_PORT}"
echo -e "  MySQL                  127.0.0.1:3306  (host-accessible)"
echo ""
echo -e "  ${BOLD}Management${RESET}"
echo -e "  ─────────────────────  ─────────────────────────────────────────────"
echo -e "  Live logs              docker compose -f deployment/docker-compose.yml logs -f"
echo -e "  Stack status           ./status.sh"
echo -e "  Rollback               cd deployment && ./rollback.sh --list"
echo -e "  Teardown               ./teardown.sh"
echo ""
hr
echo ""
