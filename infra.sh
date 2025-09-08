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
  local target=${1:-all}
  local files=()
  case "$target" in
    prod|production) files=(production/api.env production/db.env production/admin.env) ;;
    staging) files=(staging/api.env staging/db.env staging/admin.env) ;;
    all) files=(production/api.env production/db.env production/admin.env staging/api.env staging/db.env staging/admin.env) ;;
    *) err "unknown env for check_env_files (prod|staging|all)"; return 1 ;;
  esac
  local missing=()
  for f in "${files[@]}"; do
    [[ -f $f ]] || missing+=("$f")
  done
  if (( ${#missing[@]} > 0 )); then
    err "Missing env files: ${missing[*]}"; return 1
  fi
}

up_traefik() {
  title "Traefik";
  check_acme || return 1
  compose -p ritchie-proxy -f "$TRAEFIK_FILE" up -d --pull always
  ok "Traefik started"
}

up_staging() {
  title "Staging";
  check_env_files staging || return 1
  compose -p ritchie-staging --env-file "$ENV_FILE" -f "$STAGING_FILE" up -d --pull always
  ok "Staging started"
}

up_prod() {
  title "Production";
  check_env_files prod || return 1
  compose -p ritchie-prod --env-file "$ENV_FILE" -f "$PROD_FILE" up -d --pull always
  ok "Production started"
}

pull_all() {
  title "Pull images";
  compose -p ritchie-proxy -f "$TRAEFIK_FILE" pull
  compose -p ritchie-staging -f "$STAGING_FILE" pull
  compose -p ritchie-prod -f "$PROD_FILE" pull
  ok "Images updated"
}

logs() {
  local svc=${1:-traefik}
  shift || true
  docker logs -f "$svc"
}

restart_service() {
  local env=$1 svc=$2
  local file proj
  case $env in
    prod) file=$PROD_FILE; proj=ritchie-prod ;;
    staging) file=$STAGING_FILE; proj=ritchie-staging ;;
    *) err "unknown env (prod|staging)"; return 1;;
  esac
  title "Restart $svc ($env)"
  compose -p "$proj" -f "$file" up -d --pull always "$svc"
  ok "Service $svc redeployed"
}

# Prompt for a secret twice (hidden) and export value via variable indirection
prompt_secret() {
  local label=${1:-Password} outvar=$2 p1 p2
  read -s -p "$label: " p1; echo
  read -s -p "Confirm $label: " p2; echo
  if [[ "$p1" != "$p2" ]]; then
    err "Passwords do not match"; return 1
  fi
  printf -v "$outvar" '%s' "$p1"
}

# Create / ensure a superadmin by running the CLI script inside the API container
# Usage: ./infra.sh create-superadmin <env> <email>
# Optional env var: API_SUPERADMIN_CMD (default: node dist/cli/bootstrap-superadmin.js)
create_superadmin() {
  local env=$1 email=$2
  if [[ -z "${env:-}" || -z "${email:-}" ]]; then
    err "Usage: ./infra.sh create-superadmin <env> <email>"; return 1
  fi
  local file proj
  case $env in
    prod|production) file=$PROD_FILE; proj=ritchie-prod ;;
    staging) file=$STAGING_FILE; proj=ritchie-staging ;;
    *) err "unknown env (prod|staging)"; return 1;;
  esac

  local cmd="${API_SUPERADMIN_CMD:-node dist/cli/bootstrap-superadmin.js}"
  local password
  prompt_secret "Superadmin password" password || return 1

  title "Ensure superadmin ($email) on $env"
  if ! SUPERADMIN_EMAIL="$email" SUPERADMIN_PASSWORD="$password" \
      compose -p "$proj" -f "$file" run --rm --entrypoint "" \
        -e SUPERADMIN_EMAIL -e SUPERADMIN_PASSWORD api \
        sh -lc "$cmd"; then
    err "Superadmin creation failed"
    return 1
  fi
  ok "Superadmin ensured"
}

usage() {
  cat <<EOF
Usage: ./infra.sh <command>

Commands:
  up:traefik             Start/update Traefik
  up:staging             Start/update staging stack
  up:prod                Start/update production stack
  pull                   Pull all images
  restart <env> <svc>    Redeploy a service (env=prod|staging)
  logs <container>       Follow container logs
  check [env]            Verify prerequisites & env files (env=prod|staging|all, default=all)
  create-superadmin <env> <email>
                         Run superadmin bootstrap CLI inside api container

Env vars:
  API_SUPERADMIN_CMD     Override CLI command (default: node dist/cli/bootstrap-superadmin.js)

Examples:
  ./infra.sh up:traefik
  ./infra.sh up:staging
  ./infra.sh restart prod api
  ./infra.sh check staging
  ./infra.sh logs traefik
  ./infra.sh create-superadmin staging admin@example.com
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
    check) shift; check_acme && check_env_files "${1:-all}" && ok "Checks OK" ;;
    create-superadmin) shift; create_superadmin "$@" ;;
    -h|--help|help|"") usage ;;
    *) err "Unknown command"; usage; exit 1 ;;
  esac
}

main "$@"
