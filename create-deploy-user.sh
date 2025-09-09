#!/usr/bin/env bash
# Provision a non-root deployment user with SSH key.
# Idempotent: rerunning does not break existing state.
# Configurable variables (env or CLI):
#   DEPLOY_USER=deploy                User name
#   DEPLOY_GROUP=deploy               Primary group (default same as user)
#   PUBKEY_FILE=/path/key.pub         File containing the public key (else use DEPLOY_PUBKEY)
#   DEPLOY_PUBKEY="ssh-ed25519 AAAA..."  Inline public key content if no file
#   ADD_DOCKER_GROUP=true|false       Add user to docker group (true by default if group exists)
#   SUDO_COMMANDS="/usr/bin/systemctl restart docker,/usr/bin/journalctl -u docker"  Comma list of NOPASSWD sudo commands
#   CREATE_SUDO_FILE=true|false       Create sudoers drop-in if SUDO_COMMANDS set (default true)
#   DISABLE_ROOT_LOGIN=true|false     Disable PermitRootLogin (default false)
#   DISABLE_PASSWORD_AUTH=true|false  Disable PasswordAuthentication (default true)
#   SSHD_CONFIG=/etc/ssh/sshd_config  sshd_config path
#   FORCE_COMMAND=""                  If set: force this command for this key (restrict shell)
#   UMASK_HOME=0750                   Home directory mode (applied on creation)
#   DRY_RUN=true|false                Show actions without executing (default false)
# Basic usage:
#   sudo ./create-deploy-user.sh
# Example inline key:
#   sudo DEPLOY_PUBKEY="ssh-ed25519 AAAA... user@host" ./create-deploy-user.sh

set -euo pipefail

# Optional local .env-like file in same directory to parameterize without exporting globally
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
if [[ -f "$SCRIPT_DIR/.deploy-user.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.deploy-user.env"
fi

DEPLOY_USER=${DEPLOY_USER:-deploy}
DEPLOY_GROUP=${DEPLOY_GROUP:-$DEPLOY_USER}
PUBKEY_FILE=${PUBKEY_FILE:-}
DEPLOY_PUBKEY=${DEPLOY_PUBKEY:-}
ADD_DOCKER_GROUP=${ADD_DOCKER_GROUP:-}
CREATE_SUDO_FILE=${CREATE_SUDO_FILE:-}
SUDO_COMMANDS=${SUDO_COMMANDS:-}
DISABLE_ROOT_LOGIN=${DISABLE_ROOT_LOGIN:-false}
DISABLE_PASSWORD_AUTH=${DISABLE_PASSWORD_AUTH:-true}
SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
FORCE_COMMAND=${FORCE_COMMAND:-}
UMASK_HOME=${UMASK_HOME:-0750}
DRY_RUN=${DRY_RUN:-false}

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
run() { if [[ $DRY_RUN == true ]]; then echo "DRY_RUN: $*"; else eval "$*"; fi }
needs_root() { if [[ $(id -u) -ne 0 ]]; then err "Run as root (sudo)."; exit 1; fi }

needs_root

# Public key retrieval
if [[ -z $DEPLOY_PUBKEY ]]; then
  if [[ -n $PUBKEY_FILE ]]; then
    if [[ -f $PUBKEY_FILE ]]; then
      DEPLOY_PUBKEY="$(<"$PUBKEY_FILE")"
    else
      err "PUBKEY_FILE not found: $PUBKEY_FILE"; exit 1
    fi
  else
    err "Provide DEPLOY_PUBKEY or PUBKEY_FILE"; exit 1
  fi
fi

# Basic key validation
if ! grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp256)' <(echo "$DEPLOY_PUBKEY"); then
  warn "Key doesn't look like a standard SSH key — proceeding anyway."
fi

# Group
if ! getent group "$DEPLOY_GROUP" >/dev/null; then
  log "Creating group $DEPLOY_GROUP"
  run groupadd "$DEPLOY_GROUP"
else
  log "Group $DEPLOY_GROUP already exists"
fi

# User
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  log "Creating user $DEPLOY_USER"
  run useradd -m -s /bin/bash -g "$DEPLOY_GROUP" "$DEPLOY_USER"
  run chmod "$UMASK_HOME" "/home/$DEPLOY_USER"
else
  log "User $DEPLOY_USER already exists"
fi

# Docker group
if [[ -z $ADD_DOCKER_GROUP ]]; then
  if getent group docker >/dev/null; then ADD_DOCKER_GROUP=true; else ADD_DOCKER_GROUP=false; fi
fi
if [[ $ADD_DOCKER_GROUP == true ]]; then
  if getent group docker >/dev/null; then
    if id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx docker; then
      log "User already in docker group"
    else
      log "Adding $DEPLOY_USER to docker group"
      run usermod -aG docker "$DEPLOY_USER"
    fi
  else
    warn "Docker group missing – rootless Docker? Skipping."
  fi
fi

SSH_DIR="/home/$DEPLOY_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
if [[ ! -d $SSH_DIR ]]; then
  log "Creating $SSH_DIR"
  run install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" "$SSH_DIR"
fi

# Add key if absent (match start of key)
KEY_PREFIX=$(echo "$DEPLOY_PUBKEY" | awk '{print $1" "$2}')
if [[ -f $AUTH_KEYS ]] && grep -Fq "$KEY_PREFIX" "$AUTH_KEYS"; then
  log "Key already present in authorized_keys"
else
  log "Adding SSH key"
  local_line="$DEPLOY_PUBKEY"
  if [[ -n $FORCE_COMMAND ]]; then
    # Basic quotes escaping
    esc_cmd=${FORCE_COMMAND//"/\\"}
    local_line="command=\"$esc_cmd\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding $DEPLOY_PUBKEY"
  fi
  run bash -c "echo '$local_line' >> '$AUTH_KEYS'"
  run chown "$DEPLOY_USER:$DEPLOY_GROUP" "$AUTH_KEYS"
  run chmod 600 "$AUTH_KEYS"
fi

# Optional sudoers
if [[ -n $SUDO_COMMANDS ]]; then
  if [[ ${CREATE_SUDO_FILE:-true} == true ]]; then
    SUDO_FILE="/etc/sudoers.d/${DEPLOY_USER}-restricted"
    log "Configuring restricted sudo ($SUDO_FILE)"
    CMDS=$(echo "$SUDO_COMMANDS" | tr ',' ',')
    LINE="${DEPLOY_USER} ALL=(root) NOPASSWD: ${CMDS}"
    if [[ -f $SUDO_FILE ]] && grep -Fq "$LINE" "$SUDO_FILE"; then
      log "Sudo entry already present"
    else
      run bash -c "echo '$LINE' > '$SUDO_FILE'"
      run chmod 440 "$SUDO_FILE"
    fi
  fi
fi

# SSH hardening (in-place modification)
modify_sshd_config() {
  local key=$1 value=$2 file=$3
  if grep -Eq "^#?${key}\\b" "$file"; then
    run sed -i "s%^#\\?${key}.*%${key} ${value}%" "$file"
  else
    run bash -c "echo '${key} ${value}' >> '$file'"
  fi
}

RESTART_SSHD=false
if [[ $DISABLE_ROOT_LOGIN == true ]]; then
  log "Disabling root SSH login"
  modify_sshd_config PermitRootLogin no "$SSHD_CONFIG"; RESTART_SSHD=true
fi
if [[ $DISABLE_PASSWORD_AUTH == true ]]; then
  log "Disabling SSH password authentication"
  modify_sshd_config PasswordAuthentication no "$SSHD_CONFIG"; RESTART_SSHD=true
fi

if [[ $RESTART_SSHD == true ]]; then
  if command -v systemctl >/dev/null; then
    log "Reloading sshd"
    run systemctl reload sshd || run systemctl restart sshd
  else
    warn "systemctl not available – manual sshd restart required"
  fi
fi

log "Done. Test connection: ssh ${DEPLOY_USER}@<host>"
if [[ $FORCE_COMMAND ]]; then
  warn "Key forced to command '$FORCE_COMMAND' – interactive shells disabled."
fi
