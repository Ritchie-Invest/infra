#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

TRAEFIK_FILE="traefik/docker-compose.yml"
PROD_FILE="docker-compose.prod.yml"
STAGING_FILE="docker-compose.staging.yml"
ENV_FILE=".env"

YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

compose() {
  # Wrapper (docker compose v2)
  docker compose "$@"
}

title() { echo -e "${YELLOW}==> $*${NC}"; }
err() { echo -e "${RED}ERROR:${NC} $*" >&2; }
ok() { echo -e "${GREEN}$*${NC}"; }

check_prereq() {
  command -v docker >/dev/null || { err "docker missing"; exit 1; }
  docker version >/dev/null || { err "docker not working"; exit 1; }
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
  fi
}

check_acme() {
  if [[ -z "${ACME_EMAIL:-}" ]]; then
    err "ACME_EMAIL not set (define in .env)"; return 1
  fi
}

check_env_files() {
  local missing=()
  for f in production/api.env production/db.env production/admin.env \
           staging/api.env staging/db.env staging/admin.env; do
    [[ -f $f ]] || missing+=("$f")
  done
  if (( ${#missing[@]} > 0 )); then
    err "Missing env files: ${missing[*]}"; return 1
  fi
}

up_traefik() {
  title "Traefik";
  check_acme || return 1
  compose -f "$TRAEFIK_FILE" up -d --pull always
  ok "Traefik started"
}

up_staging() {
  title "Staging";
  check_env_files || return 1
  compose --env-file "$ENV_FILE" -f "$STAGING_FILE" up -d --pull always
  ok "Staging started"
}

up_prod() {
  title "Production";
  check_env_files || return 1
  compose --env-file "$ENV_FILE" -f "$PROD_FILE" up -d --pull always
  ok "Production started"
}

pull_all() {
  title "Pull images";
  compose -f "$TRAEFIK_FILE" pull
  compose -f "$STAGING_FILE" pull
  compose -f "$PROD_FILE" pull
  ok "Images updated"
}

logs() {
  local svc=${1:-traefik}
  shift || true
  docker logs -f "$svc"
}

restart_service() {
  local env=$1 svc=$2
  local file
  case $env in
    prod) file=$PROD_FILE;;
    staging) file=$STAGING_FILE;;
    *) err "unknown env (prod|staging)"; return 1;;
  esac
  title "Restart $svc ($env)"
  compose -f "$file" up -d --pull always "$svc"
  ok "Service $svc redeployed"
}

usage() {
  cat <<EOF
Usage: ./infra.sh <command>

Commands:
  up:traefik          Start/update Traefik
  up:staging          Start/update staging stack
  up:prod             Start/update production stack
  pull                Pull all images
  restart <env> <svc> Redeploy a service (env=prod|staging)
  logs <container>    Follow container logs
  check               Verify prerequisites & env files

Examples:
  ./infra.sh up:traefik
  ./infra.sh up:staging
  ./infra.sh restart prod api
  ./infra.sh logs traefik
EOF
}

main() {
  check_prereq
  load_env
  case ${1:-} in
    up:traefik) up_traefik ;;
    up:staging) up_staging ;;
    up:prod) up_prod ;;
    pull) pull_all ;;
    restart) shift; restart_service "$@" ;;
    logs) shift; logs "$@" ;;
    check) check_acme && check_env_files && ok "Checks OK" ;;
    -h|--help|help|"") usage ;;
    *) err "Unknown command"; usage; exit 1 ;;
  esac
}

main "$@"
