#!/usr/bin/env bash
# =============================================================================
# rollback.sh – Switch one or more services to a previously loaded image tag
#
# This never downloads anything – it only switches between images already
# present in the local Docker daemon (loaded via deploy-local.sh previously).
#
# Usage:
#   ./rollback.sh                               # interactive tag picker
#   ./rollback.sh --backend-tag 3.2.5-abc1234  # explicit backend rollback
#   ./rollback.sh --frontend-tag 1.0.0-abc1234 # explicit frontend rollback
#   ./rollback.sh --list                        # list available local tags
#
# Options:
#   --backend-tag  <tag>   Roll backend  to this tag
#   --frontend-tag <tag>   Roll frontend to this tag
#   --list                 List available local image tags per service
#   -h, --help
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

BACKEND_TAG=""
FRONTEND_TAG=""
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-tag)  BACKEND_TAG="$2";  shift 2 ;;
    --frontend-tag) FRONTEND_TAG="$2"; shift 2 ;;
    --list)         LIST_ONLY=true;    shift   ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── List available local image tags ───────────────────────────────────────────
list_tags() {
  local IMAGE="$1"
  docker images "${IMAGE}" --format "{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}" \
    | sort -r \
    | awk -v img="$IMAGE" \
        'BEGIN{printf "%-40s  %-20s  %s\n","TAG","CREATED","SIZE"}
         {printf "%-40s  %-20s  %s\n",$1,$2,$3}'
}

if [[ "$LIST_ONLY" == "true" ]]; then
  echo -e "\n${BOLD}Backend (shopizer-backend):${RESET}"
  list_tags "shopizer-backend"
  echo -e "\n${BOLD}Frontend (shopizer-frontend):${RESET}"
  list_tags "shopizer-frontend"
  exit 0
fi

# ── Interactive picker if no args given ───────────────────────────────────────
if [[ -z "$BACKEND_TAG" && -z "$FRONTEND_TAG" ]]; then
  echo -e "\n${BOLD}Available backend tags:${RESET}"
  list_tags "shopizer-backend"
  echo ""
  read -rp "Enter backend tag to roll back to (Enter to skip): " BACKEND_TAG
  echo -e "\n${BOLD}Available frontend tags:${RESET}"
  list_tags "shopizer-frontend"
  echo ""
  read -rp "Enter frontend tag to roll back to (Enter to skip): " FRONTEND_TAG
fi

[[ -z "$BACKEND_TAG" && -z "$FRONTEND_TAG" ]] && {
  warn "No tags provided – nothing to do."
  exit 0
}

# ── Validate that requested tags exist locally ────────────────────────────────
validate_tag() {
  local IMAGE="$1" TAG="$2"
  if [[ -n "$TAG" ]]; then
    if ! docker image inspect "${IMAGE}:${TAG}" > /dev/null 2>&1; then
      error "Image ${IMAGE}:${TAG} not found locally. Run deploy-local.sh --*-tag ${TAG} first."
    fi
  fi
}
validate_tag "shopizer-backend"  "$BACKEND_TAG"
validate_tag "shopizer-frontend" "$FRONTEND_TAG"

# ── Record current tags (for undo reference) ──────────────────────────────────
PREV_FILE="${SCRIPT_DIR}/.rollback-history"
set -a; source "$ENV_FILE" 2>/dev/null || true; set +a

cat >> "$PREV_FILE" << EOF
$(date -u +%Y-%m-%dT%H:%M:%SZ)  backend=${IMAGE_TAG_BACKEND:-latest}  frontend=${IMAGE_TAG_FRONTEND:-latest}
EOF
info "Previous tags saved to .rollback-history"

# ── Update .env ───────────────────────────────────────────────────────────────
update_env() {
  local KEY="$1" VAL="$2"
  [[ -z "$VAL" ]] && return
  if grep -q "^${KEY}=" "$ENV_FILE" 2>/dev/null; then
    sed -i '' "s|^${KEY}=.*|${KEY}=${VAL}|" "$ENV_FILE"
  else
    echo "${KEY}=${VAL}" >> "$ENV_FILE"
  fi
}

[[ -n "$BACKEND_TAG"  ]] && update_env "IMAGE_TAG_BACKEND"  "$BACKEND_TAG"
[[ -n "$FRONTEND_TAG" ]] && update_env "IMAGE_TAG_FRONTEND" "$FRONTEND_TAG"

# ── Restart affected services ─────────────────────────────────────────────────
cd "$SCRIPT_DIR"
set -a; source "$ENV_FILE"; set +a

SERVICES=()
[[ -n "$BACKEND_TAG"  ]] && SERVICES+=("shopizer-backend")
[[ -n "$FRONTEND_TAG" ]] && SERVICES+=("shopizer-frontend")

info "Restarting: ${SERVICES[*]}"
docker compose up -d --no-deps --no-build "${SERVICES[@]}"

success "Rollback complete."
echo -e "  Backend  : ${BOLD}${IMAGE_TAG_BACKEND:-unchanged}${RESET}"
echo -e "  Frontend : ${BOLD}${IMAGE_TAG_FRONTEND:-unchanged}${RESET}"
echo ""
echo "To undo this rollback, check .rollback-history and re-run with previous tags."
