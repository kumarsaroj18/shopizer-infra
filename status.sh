#!/usr/bin/env bash
# =============================================================================
# status.sh – Shopizer local stack health dashboard
#
# Prints a concise summary of:
#   • Colima VM state (CPU, memory, disk, arch)
#   • Docker context
#   • Container states and health checks
#   • HTTP health endpoint reachability
#   • Loaded image tags with sizes
#
# Usage:
#   ./status.sh [--json]
#
# Options:
#   --json    Emit a machine-readable JSON summary (requires jq)
#   -h        Show this help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="${SCRIPT_DIR}/deployment"
COLIMA_PROFILE="shopizer"
DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

badge_ok()   { echo -e "${GREEN}● running${RESET}"; }
badge_warn() { echo -e "${YELLOW}● degraded${RESET}"; }
badge_down() { echo -e "${RED}● stopped${RESET}"; }
hr() { echo -e "  ${DIM}────────────────────────────────────────────────────${RESET}"; }

JSON_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=true; shift ;;
    -h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Gather info ───────────────────────────────────────────────────────────────

# ── 1. Colima VM
COLIMA_RAW="$(colima list 2>/dev/null || echo '')"
COLIMA_RUNNING=false
COLIMA_LINE=""
if echo "$COLIMA_RAW" | grep -q "^${COLIMA_PROFILE}"; then
  COLIMA_LINE="$(echo "$COLIMA_RAW" | grep "^${COLIMA_PROFILE}")"
  if echo "$COLIMA_LINE" | grep -qi "running"; then
    COLIMA_RUNNING=true
  fi
fi

# ── 2. Docker context
CURRENT_CTX="$(docker context show 2>/dev/null || echo 'none')"

# ── 3. Container status (requires Docker to be reachable)
get_container_info() {
  local NAME="$1"
  if ! docker inspect "$NAME" &>/dev/null; then
    echo "absent|none|none"
    return
  fi
  local STATUS HEALTH IMAGE TAG
  STATUS="$(docker inspect --format='{{.State.Status}}'        "$NAME" 2>/dev/null)"
  HEALTH="$(docker inspect --format='{{.State.Health.Status}}' "$NAME" 2>/dev/null \
            || echo 'none')"
  IMAGE="$(docker  inspect --format='{{.Config.Image}}'        "$NAME" 2>/dev/null)"
  echo "${STATUS}|${HEALTH}|${IMAGE}"
}

if [[ "$COLIMA_RUNNING" == "true" ]] && docker context use "${DOCKER_CONTEXT}" &>/dev/null; then
  MYSQL_INFO="$(get_container_info    shopizer-mysql)"
  BACKEND_INFO="$(get_container_info  shopizer-backend)"
  FRONTEND_INFO="$(get_container_info shopizer-frontend)"
else
  MYSQL_INFO="absent|none|none"
  BACKEND_INFO="absent|none|none"
  FRONTEND_INFO="absent|none|none"
fi

parse_status() { echo "$1" | cut -d'|' -f1; }
parse_health()  { echo "$1" | cut -d'|' -f2; }
parse_image()   { echo "$1" | cut -d'|' -f3; }

container_badge() {
  local STATUS="$1" HEALTH="$2"
  case "$STATUS" in
    running)
      case "$HEALTH" in
        healthy)   echo -e "${GREEN}● healthy${RESET}" ;;
        starting)  echo -e "${YELLOW}● starting${RESET}" ;;
        unhealthy) echo -e "${RED}● unhealthy${RESET}" ;;
        none)      echo -e "${GREEN}● running${RESET}" ;;
        absent)    echo -e "${DIM}● no-healthcheck${RESET}" ;;
        *)         echo -e "${YELLOW}● ${HEALTH}${RESET}" ;;
      esac ;;
    exited|stopped) echo -e "${RED}● stopped${RESET}" ;;
    absent) echo -e "${DIM}● not created${RESET}" ;;
    *)      echo -e "${YELLOW}● ${STATUS}${RESET}" ;;
  esac
}

# ── 4. HTTP endpoint checks
check_http() {
  local URL="$1"
  if curl -sf --max-time 3 "$URL" &>/dev/null; then
    echo -e "${GREEN}reachable${RESET}"
  else
    echo -e "${RED}unreachable${RESET}"
  fi
}

BACKEND_STATUS="$(parse_status "$BACKEND_INFO")"
if [[ "$BACKEND_STATUS" == "running" ]]; then
  HTTP_API="$(check_http "http://localhost:8080/actuator/health")"
  HTTP_SWAGGER="$(check_http "http://localhost:8080/swagger-ui/index.html")"
else
  HTTP_API="${RED}─${RESET}"
  HTTP_SWAGGER="${RED}─${RESET}"
fi

FRONTEND_STATUS="$(parse_status "$FRONTEND_INFO")"
ADMIN_PORT="${ADMIN_PORT:-8081}"
SHOP_PORT="${SHOP_PORT:-8082}"
if [[ "$FRONTEND_STATUS" == "running" ]]; then
  HTTP_ADMIN="$(check_http "http://localhost:${ADMIN_PORT}/")"
  HTTP_SHOP="$(check_http  "http://localhost:${SHOP_PORT}/")"
else
  HTTP_ADMIN="${RED}─${RESET}"
  HTTP_SHOP="${RED}─${RESET}"
fi

# ── 5. Loaded image tags & sizes
list_images() {
  local PATTERN="$1"
  docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null \
    | grep "^${PATTERN}" \
    | sort -k1,1 \
    | sed 's/^/    /' \
    || echo "    (none)"
}

# ════════════════════════════════════════════════════════════════════════════
# JSON output
# ════════════════════════════════════════════════════════════════════════════
if [[ "$JSON_MODE" == "true" ]]; then
  command -v jq &>/dev/null || { echo '{"error":"jq not installed"}'; exit 1; }

  jq -n \
    --arg colima_running "$COLIMA_RUNNING" \
    --arg docker_context "$CURRENT_CTX" \
    --arg mysql_status    "$(parse_status "$MYSQL_INFO")" \
    --arg mysql_health    "$(parse_health "$MYSQL_INFO")" \
    --arg backend_status  "$(parse_status "$BACKEND_INFO")" \
    --arg backend_health  "$(parse_health "$BACKEND_INFO")" \
    --arg frontend_status "$(parse_status "$FRONTEND_INFO")" \
    --arg frontend_health "$(parse_health "$FRONTEND_INFO")" \
    '{
      colima:  { running: ($colima_running == "true") },
      docker:  { context: $docker_context },
      containers: {
        mysql:    { status: $mysql_status,    health: $mysql_health },
        backend:  { status: $backend_status,  health: $backend_health },
        frontend: { status: $frontend_status, health: $frontend_health }
      }
    }'
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# Human-readable Dashboard
# ════════════════════════════════════════════════════════════════════════════
clear 2>/dev/null || true
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Shopizer  ·  Local Stack Status Dashboard            ║${RESET}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Infrastructure ────────────────────────────────────────────────────────────
echo -e "  ${BOLD}Infrastructure${RESET}"
hr

# Colima
if [[ "$COLIMA_RUNNING" == "true" ]]; then
  echo -e "  Colima VM   : $(badge_ok)"
  if [[ -n "$COLIMA_LINE" ]]; then
    # Parse columns: NAME STATUS ARCH CPUS MEMORY DISK RUNTIME
    VM_ARCH="$(echo "$COLIMA_LINE" | awk '{print $3}')"
    VM_CPU="$(echo  "$COLIMA_LINE" | awk '{print $4}')"
    VM_MEM="$(echo  "$COLIMA_LINE" | awk '{print $5}')"
    VM_DISK="$(echo "$COLIMA_LINE" | awk '{print $6}')"
    echo -e "  VM Spec     : ${VM_CPU} vCPU · ${VM_MEM} RAM · ${VM_DISK} disk · arch=${VM_ARCH}"
  fi
else
  echo -e "  Colima VM   : $(badge_down)"
  echo -e "  ${DIM}Run ./provision.sh to start${RESET}"
fi
echo -e "  Docker ctx  : ${BOLD}${CURRENT_CTX}${RESET}"

echo ""
echo -e "  ${BOLD}Containers${RESET}"
hr

printf "  %-22s %-24s %s\n" "NAME" "STATE / HEALTH" "IMAGE"
printf "  %-22s %-24s %s\n" "──────────────────" "──────────────────" "─────────────────────────────"

for ROW in \
  "shopizer-mysql|${MYSQL_INFO}" \
  "shopizer-backend|${BACKEND_INFO}" \
  "shopizer-frontend|${FRONTEND_INFO}"; do
  CTR_NAME="${ROW%%|*}"
  CTR_DATA="${ROW#*|}"
  CTR_STATUS="$(parse_status "$CTR_DATA")"
  CTR_HEALTH="$(parse_health "$CTR_DATA")"
  CTR_IMAGE="$(parse_image   "$CTR_DATA")"
  BADGE="$(container_badge "$CTR_STATUS" "$CTR_HEALTH")"
  # Strip color codes for printf width calculation
  PLAIN_BADGE="$(echo -e "$BADGE" | sed 's/\x1b\[[0-9;]*m//g')"
  PAD=$(( 24 - ${#PLAIN_BADGE} ))
  printf "  %-22s %b%*s%s\n" "$CTR_NAME" "$BADGE" "$PAD" "" "$CTR_IMAGE"
done

echo ""
echo -e "  ${BOLD}Service URLs & Reachability${RESET}"
hr

printf "  %-36s %s\n" "URL" "STATUS"
printf "  %-36s %s\n" "────────────────────────────────" "──────────"

printf "  %-36s " "http://localhost:8080/actuator/health"
echo -e "$HTTP_API"

printf "  %-36s " "http://localhost:8080/swagger-ui/"
echo -e "$HTTP_SWAGGER"

printf "  %-36s " "http://localhost:${ADMIN_PORT}/ (Admin UI)"
echo -e "$HTTP_ADMIN"

printf "  %-36s " "http://localhost:${SHOP_PORT}/ (React Shop)"
echo -e "$HTTP_SHOP"

echo ""
echo -e "  ${BOLD}Docker Images${RESET}"
hr

if [[ "$COLIMA_RUNNING" == "true" ]]; then
  echo -e "  ${DIM}shopizer-*${RESET}"
  list_images "shopizer"
else
  echo -e "  ${DIM}(Colima is not running – cannot query images)${RESET}"
fi

echo ""
hr
echo ""
echo -e "  ${DIM}Provision:  ./provision.sh  |  Teardown: ./teardown.sh  |  Deploy: cd deployment && ./deploy-local.sh${RESET}"
echo ""
