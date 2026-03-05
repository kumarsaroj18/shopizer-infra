#!/usr/bin/env bash
# =============================================================================
# teardown.sh – Graceful teardown of the Shopizer local stack
#
# Levels of teardown (controlled by flags):
#
#   (default)       Stop and remove app containers; keep MySQL data volumes
#                   and the Colima VM running.
#
#   --volumes       Also delete MySQL data volumes (full data wipe).
#
#   --stop-colima   Also stop the Colima VM (releases CPU/RAM on your Mac).
#                   Containers and volumes are removed first.
#
#   --destroy-vm    Stop and DELETE the Colima VM entirely (removes the profile
#                   from ~/.colima/shopizer).  Use this to reclaim disk space or
#                   before re-provisioning from scratch.
#                   ⚠  This is irreversible – all container state is lost.
#
# Usage:
#   ./teardown.sh [--volumes] [--stop-colima | --destroy-vm] [-y]
#
# Options:
#   --volumes       Remove MySQL data volumes (loses all DB data)
#   --stop-colima   Stop the Colima VM after removing containers
#   --destroy-vm    Delete the Colima VM profile entirely
#   -y, --yes       Skip all confirmation prompts (for scripted use)
#   -h, --help      Show this help
#
# Examples:
#   ./teardown.sh                        # Stop containers; keep volumes & VM
#   ./teardown.sh --volumes              # Stop containers AND wipe all data
#   ./teardown.sh --stop-colima          # Stop containers + pause VM
#   ./teardown.sh --destroy-vm -y        # Nuclear teardown, no prompts
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="${SCRIPT_DIR}/deployment"
COLIMA_PROFILE="shopizer"
DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
ok()    { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error() { echo -e "\n  ${RED}✖  ERROR: $*${RESET}\n" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────────────────────
REMOVE_VOLUMES=false
STOP_COLIMA=false
DESTROY_VM=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volumes)     REMOVE_VOLUMES=true;  shift ;;
    --stop-colima) STOP_COLIMA=true;     shift ;;
    --destroy-vm)  DESTROY_VM=true;      STOP_COLIMA=true; shift ;;
    -y|--yes)      AUTO_YES=true;        shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Confirmation helper ───────────────────────────────────────────────────────
confirm() {
  local PROMPT="$1"
  if [[ "$AUTO_YES" == "true" ]]; then
    return 0
  fi
  echo -e "\n  ${YELLOW}${PROMPT}${RESET}"
  read -r -p "  Continue? [y/N] " REPLY
  [[ "${REPLY,,}" == "y" ]] || { echo "  Aborted."; exit 0; }
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Shopizer  ·  IaC Teardown                   ║${RESET}"
echo -e "${BOLD}╚════════════════════════════════════════════════╝${RESET}"
echo ""
info "Teardown level:"
info "  Remove volumes : ${REMOVE_VOLUMES}"
info "  Stop Colima VM : ${STOP_COLIMA}"
info "  Destroy VM     : ${DESTROY_VM}"
echo ""

# ── Warn on destructive operations ────────────────────────────────────────────
if [[ "$REMOVE_VOLUMES" == "true" ]]; then
  confirm "⚠  --volumes is set. ALL MySQL data will be permanently deleted."
fi
if [[ "$DESTROY_VM" == "true" ]]; then
  confirm "⚠  --destroy-vm is set. The Colima '${COLIMA_PROFILE}' VM will be DELETED."
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. Stop and remove app containers
# ════════════════════════════════════════════════════════════════════════════
echo ""
info "Stopping application containers…"

COMPOSE_FILE="${DEPLOYMENT_DIR}/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  warn "docker-compose.yml not found at ${COMPOSE_FILE}; skipping compose down"
else
  # Try to use the Colima Docker context, but proceed regardless
  docker context use "${DOCKER_CONTEXT}" &>/dev/null || true

  # Check if docker is accessible (containers might exist)
  DOCKER_ACCESSIBLE=false
  CONTAINERS_EXIST=false
  
  if docker ps -q 2>/dev/null | grep -q .; then
    DOCKER_ACCESSIBLE=true
    CONTAINERS_EXIST=true
  elif docker ps -a -q 2>/dev/null | grep -q .; then
    DOCKER_ACCESSIBLE=true
  fi

  if [[ "$DOCKER_ACCESSIBLE" == "true" ]]; then
    cd "${DEPLOYMENT_DIR}"
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
      docker compose down -v --remove-orphans 2>&1 | sed 's/^/    /'
      ok "Containers and volumes removed"
    else
      docker compose down --remove-orphans 2>&1 | sed 's/^/    /'
      ok "Containers removed (volumes retained)"
    fi
  else
    warn "Docker is not accessible; cannot stop containers"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 2. Stop the Colima VM (optional)
# ════════════════════════════════════════════════════════════════════════════
if [[ "$STOP_COLIMA" == "true" ]]; then
  echo ""
  info "Stopping Colima VM (profile: ${COLIMA_PROFILE})…"

  if colima status "${COLIMA_PROFILE}" 2>&1 | grep -q "running"; then
    colima stop "${COLIMA_PROFILE}"
    ok "Colima VM '${COLIMA_PROFILE}' stopped"
  else
    ok "Colima VM '${COLIMA_PROFILE}' is not running (nothing to stop)"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 3. Destroy the Colima VM profile (optional)
# ════════════════════════════════════════════════════════════════════════════
if [[ "$DESTROY_VM" == "true" ]]; then
  echo ""
  info "Deleting Colima VM profile '${COLIMA_PROFILE}'…"

  colima delete "${COLIMA_PROFILE}" --force 2>&1 | sed 's/^/    /' || true
  ok "Colima profile '${COLIMA_PROFILE}' deleted"

  # Remove the applied colima.yaml from the profile directory (now gone anyway)
  CONFIG_DIR="${HOME}/.colima/${COLIMA_PROFILE}"
  [[ -d "$CONFIG_DIR" ]] && rm -rf "$CONFIG_DIR" && ok "Removed ~/.colima/${COLIMA_PROFILE}"

  # Clean up the Docker context if it still exists
  if docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx "${DOCKER_CONTEXT}"; then
    docker context rm "${DOCKER_CONTEXT}" 2>/dev/null || true
    ok "Removed Docker context '${DOCKER_CONTEXT}'"
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
ok "Teardown complete."
echo ""

if [[ "$DESTROY_VM" != "true" ]]; then
  echo -e "  ${BOLD}What was kept:${RESET}"
  if [[ "$REMOVE_VOLUMES" == "false" ]]; then
    echo -e "    Docker volumes (MySQL data)  → re-provision will reuse existing data"
  fi
  if [[ "$STOP_COLIMA" == "false" ]]; then
    echo -e "    Colima VM '${COLIMA_PROFILE}'          → still running, consuming ${CYAN}~4 GB RAM${RESET}"
  fi
  echo ""
  echo -e "  To restart: ${BOLD}./provision.sh --skip-brew --skip-images${RESET}"
  echo -e "  To start fresh: ${BOLD}./teardown.sh --volumes && ./provision.sh${RESET}"
fi
echo ""
