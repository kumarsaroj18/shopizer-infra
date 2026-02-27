#!/usr/bin/env bash
# =============================================================================
# deploy-local.sh – Pull Docker image artifacts from GitHub and start locally
#
# Prerequisites: colima, docker, gh (GitHub CLI), docker compose v2
#
# Usage:
#   ./deploy-local.sh [OPTIONS]
#
# Options:
#   --backend-tag  <tag>   Image tag for backend       (e.g. 3.2.5-a1b2c3d4)
#   --frontend-tag <tag>   Image tag for combined frontend  (e.g. 1.0.0-a1b2c3d4)
#   --skip-pull           Skip GitHub artifact download (use already-loaded images)
#   --only-backend        Only update the backend service
#   -h, --help            Show this help
#
# Example – deploy specific versions:
#   ./deploy-local.sh --backend-tag 3.2.5-a1b2c3d4
#
# Example – full stack with explicit tags:
#   ./deploy-local.sh \
#     --backend-tag  3.2.5-a1b2c3d4 \
#     --frontend-tag 1.0.0-b2c3d4e5
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
BACKEND_TAG=""
FRONTEND_TAG=""
SKIP_PULL=false
ONLY_BACKEND=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-tag)  BACKEND_TAG="$2";  shift 2 ;;
    --frontend-tag) FRONTEND_TAG="$2"; shift 2 ;;
    --skip-pull)    SKIP_PULL=true;    shift   ;;
    --only-backend) ONLY_BACKEND=true; shift   ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# ====/p' "$0" | head -n 25
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  warn ".env not found – copying from .env.example"
  cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
  error "Please fill in ${ENV_FILE} before proceeding."
fi
# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

# Apply CLI overrides (CLI takes precedence over .env)
[[ -n "$BACKEND_TAG"  ]] && IMAGE_TAG_BACKEND="$BACKEND_TAG"
[[ -n "$FRONTEND_TAG" ]] && IMAGE_TAG_FRONTEND="$FRONTEND_TAG"

# ── Preflight checks ──────────────────────────────────────────────────────────
info "Running preflight checks…"

command -v colima  >/dev/null || error "colima not found. Install: brew install colima"
command -v docker  >/dev/null || error "docker not found. Install: brew install docker"
command -v gh      >/dev/null || error "GitHub CLI not found. Install: brew install gh"

# Ensure Colima is running
if ! colima status 2>/dev/null | grep -q "running"; then
  info "Starting Colima (2 CPU, 4 GB RAM, 60 GB disk)…"
  colima start --cpu 2 --memory 4 --disk 60 --arch aarch64 --vm-type vz
  sleep 5
fi
success "Colima is running"

# Ensure Docker daemon is reachable
docker info > /dev/null 2>&1 || error "Docker daemon not responding"
success "Docker daemon is reachable"

# ── Pull image tars from GitHub ───────────────────────────────────────────────
pull_and_load() {
  local SERVICE="$1"        # backend | admin | react
  local TAG="$2"            # e.g. 3.2.5-a1b2c3d4
  local ARTIFACT_PATTERN="$3"   # e.g. docker-image-backend-*
  local REPO_VAR="GITHUB_REPO_$(echo "$SERVICE" | tr '[:lower:]' '[:upper:]')"
  local REPO="${!REPO_VAR:-}"
  local CACHE_DIR="${SCRIPT_DIR}/.image-cache"

  mkdir -p "$CACHE_DIR"

  if [[ "$SKIP_PULL" == "true" ]]; then
    info "Skipping pull for ${SERVICE} (--skip-pull)"
    return 0
  fi

  if [[ "$TAG" == "latest" ]]; then
    warn "Tag for ${SERVICE} is 'latest' – skipping GitHub pull (using locally available image)"
    return 0
  fi

  if [[ -z "$REPO" ]]; then
    warn "GITHUB_REPO_${SERVICE^^} not set in .env – skipping pull for ${SERVICE}"
    return 0
  fi

  local TAR_FILE="${CACHE_DIR}/shopizer-${SERVICE}-${TAG}.tar.gz"

  if [[ -f "$TAR_FILE" ]]; then
    info "Cache hit: ${TAR_FILE}"
  else
    info "Downloading ${SERVICE} image (tag=${TAG}) from ${REPO}…"
    gh run download \
      --repo "$REPO" \
      --pattern "${ARTIFACT_PATTERN}" \
      --dir "$CACHE_DIR" \
      $(gh run list \
          --repo "$REPO" \
          --workflow "CD*" \
          --status success \
          --json databaseId,headBranch \
          --jq ".[0].databaseId") || {
      # Fallback: search any run containing this image artifact
      warn "Could not auto-resolve run ID; trying latest successful CD run…"
      gh run download \
        --repo "$REPO" \
        --pattern "${ARTIFACT_PATTERN}" \
        --dir "$CACHE_DIR"
    }
    # Find the downloaded tar
    TAR_FILE=$(find "$CACHE_DIR" -name "shopizer-${SERVICE}-*.tar.gz" | sort -r | head -1)
    [[ -z "$TAR_FILE" ]] && error "Could not find downloaded image tar for ${SERVICE}"
  fi

  info "Loading image: ${TAR_FILE}"
  docker load < "$TAR_FILE"
  success "Loaded ${SERVICE} image"
}

if [[ "$ONLY_BACKEND" == "true" ]]; then
  pull_and_load "backend"  "$IMAGE_TAG_BACKEND"  "docker-image-backend-*"
else
  pull_and_load "backend"  "$IMAGE_TAG_BACKEND"  "docker-image-backend-*"
  pull_and_load "frontend" "$IMAGE_TAG_FRONTEND" "docker-image-frontend-*"
fi

# ── Write final .env with resolved tags ───────────────────────────────────────
info "Writing resolved tags to .env…"
# sed-in-place update for the three tag lines
update_env() {
  local KEY="$1" VAL="$2"
  if grep -q "^${KEY}=" "$ENV_FILE"; then
    sed -i '' "s|^${KEY}=.*|${KEY}=${VAL}|" "$ENV_FILE"
  else
    echo "${KEY}=${VAL}" >> "$ENV_FILE"
  fi
}
update_env "IMAGE_TAG_BACKEND"  "$IMAGE_TAG_BACKEND"
update_env "IMAGE_TAG_FRONTEND" "$IMAGE_TAG_FRONTEND"

echo ""
info "Active image tags:"
echo -e "  Backend  : ${BOLD}${IMAGE_TAG_BACKEND}${RESET}"
echo -e "  Frontend : ${BOLD}${IMAGE_TAG_FRONTEND}${RESET}"
echo ""

# ── Start / update containers ─────────────────────────────────────────────────
info "Starting services with docker compose…"
cd "$SCRIPT_DIR"

if [[ "$ONLY_BACKEND" == "true" ]]; then
  docker compose up -d --no-deps shopizer-backend
else
  docker compose up -d
fi

# ── Wait for backend health ───────────────────────────────────────────────────
info "Waiting for shopizer-backend to become healthy…"
TIMEOUT=120
ELAPSED=0
until docker inspect --format='{{.State.Health.Status}}' shopizer-backend 2>/dev/null \
      | grep -q "healthy"; do
  sleep 5; ELAPSED=$((ELAPSED+5))
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    warn "Backend did not become healthy within ${TIMEOUT}s"
    docker logs --tail 50 shopizer-backend
    break
  fi
  echo -n "."
done
echo ""

# ── Print access URLs ──────────────────────────────────────────────────────────
success "Stack is up."
echo ""
echo -e " ${BOLD}Service URLs${RESET}"
echo -e " ─────────────────────────────────────────────"
echo -e " API Backend : http://localhost:8080/swagger-ui/index.html"
echo -e " Admin UI    : http://localhost:${ADMIN_PORT:-8081}"
echo -e " React Shop  : http://localhost:${SHOP_PORT:-8082}"
echo ""
echo -e " Logs        : docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs -f"
echo -e " Teardown    : docker compose -f ${SCRIPT_DIR}/docker-compose.yml down"
echo ""
