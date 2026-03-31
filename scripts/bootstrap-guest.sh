#!/usr/bin/env bash

set -euo pipefail

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "missing required variable: $name" >&2
        exit 1
    fi
}

require_var DEVVM_GUEST_USER
require_var DEVVM_WORKSPACE_DIR
require_var DEVVM_REPO_DIR
require_var DEVVM_SOURCE_REPO
require_var DEVVM_ALLOWED_OUTBOUND_PORTS
require_var DEVVM_OPENCODE_DOWNLOAD_URL
require_var DEVVM_OPENCODE_SHA256
require_var DEVVM_REMOTE_DIR

SECRETS_FILE="${DEVVM_REMOTE_DIR}/secrets.env"

if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "missing staged secrets file: $SECRETS_FILE" >&2
    exit 1
fi

set -a
source "$SECRETS_FILE"
set +a

install -d -m 0755 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" "$DEVVM_WORKSPACE_DIR"
install -d -m 0700 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" "/home/${DEVVM_GUEST_USER}/.ssh"
install -d -m 0700 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" "/home/${DEVVM_GUEST_USER}/.config/opencode"

git_ssh_command=""

cat > "/home/${DEVVM_GUEST_USER}/.gitconfig" <<EOF
[user]
    name = ${GIT_USER_NAME}
    email = ${GIT_USER_EMAIL}
EOF
chown "$DEVVM_GUEST_USER:$DEVVM_GUEST_USER" "/home/${DEVVM_GUEST_USER}/.gitconfig"
chmod 0644 "/home/${DEVVM_GUEST_USER}/.gitconfig"

if [[ -n "${DEVVM_SSH_KNOWN_HOSTS_STAGED:-}" ]]; then
    if [[ ! -f "${DEVVM_SSH_KNOWN_HOSTS_STAGED}" ]]; then
        echo "missing staged known_hosts file: ${DEVVM_SSH_KNOWN_HOSTS_STAGED}" >&2
        exit 1
    fi
    install -m 0644 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" \
        "$DEVVM_SSH_KNOWN_HOSTS_STAGED" "/home/${DEVVM_GUEST_USER}/.ssh/known_hosts"
    git_ssh_command="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/${DEVVM_GUEST_USER}/.ssh/known_hosts"
fi

if [[ -n "${DEVVM_OPENCODE_CONFIG_PATH:-}" && -n "${DEVVM_OPENCODE_CONFIG_STAGED:-}" && -f "${DEVVM_OPENCODE_CONFIG_STAGED}" ]]; then
    install -d -m 0700 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" "$(dirname "$DEVVM_OPENCODE_CONFIG_PATH")"
    install -m 0600 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" "$DEVVM_OPENCODE_CONFIG_STAGED" "$DEVVM_OPENCODE_CONFIG_PATH"
fi

ufw --force reset
ufw default deny outgoing
ufw default deny incoming
IFS=',' read -r -a PORTS <<< "$DEVVM_ALLOWED_OUTBOUND_PORTS"
for port in "${PORTS[@]}"; do
    ufw allow out "$port"
done
ufw --force enable

if [[ "${DEVVM_DISABLE_SSH:-false}" == "true" ]]; then
    systemctl disable --now ssh || systemctl disable --now sshd || true
fi

tmp_binary="/tmp/opencode-binary"
curl -fsSL "$DEVVM_OPENCODE_DOWNLOAD_URL" -o "$tmp_binary"
echo "${DEVVM_OPENCODE_SHA256}  ${tmp_binary}" | sha256sum -c
if [[ "$DEVVM_OPENCODE_DOWNLOAD_URL" == *.tar.gz ]]; then
    tmp_extract_dir="$(mktemp -d)"
    tar -xzf "$tmp_binary" -C "$tmp_extract_dir"
    install -m 0755 "$tmp_extract_dir/opencode" /usr/local/bin/opencode
    rm -rf "$tmp_extract_dir"
else
    install -m 0755 "$tmp_binary" /usr/local/bin/opencode
fi
rm -f "$tmp_binary"
opencode --version >/dev/null

repo_parent="$(dirname "$DEVVM_REPO_DIR")"
install -d -m 0755 -o "$DEVVM_GUEST_USER" -g "$DEVVM_GUEST_USER" "$repo_parent"
if [[ ! -d "$DEVVM_REPO_DIR/.git" ]]; then
    if [[ -n "$git_ssh_command" ]]; then
        sudo -u "$DEVVM_GUEST_USER" env GIT_SSH_COMMAND="$git_ssh_command" git clone "$DEVVM_SOURCE_REPO" "$DEVVM_REPO_DIR"
    else
        sudo -u "$DEVVM_GUEST_USER" git clone "$DEVVM_SOURCE_REPO" "$DEVVM_REPO_DIR"
    fi
fi
if [[ -n "${DEVVM_SOURCE_BRANCH:-}" ]]; then
    if [[ -n "$git_ssh_command" ]]; then
        sudo -u "$DEVVM_GUEST_USER" env GIT_SSH_COMMAND="$git_ssh_command" git -C "$DEVVM_REPO_DIR" checkout "$DEVVM_SOURCE_BRANCH"
    else
        sudo -u "$DEVVM_GUEST_USER" git -C "$DEVVM_REPO_DIR" checkout "$DEVVM_SOURCE_BRANCH"
    fi
fi

deluser "$DEVVM_GUEST_USER" sudo || true
