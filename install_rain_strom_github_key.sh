#!/usr/bin/env bash
set -euo pipefail

# Install rain-strom's public GitHub keys for SSH login to the current server.
# Run this script as the user who should receive access.

GITHUB_USER="${GITHUB_USER:-rain-strom}"
KEYS_URL="https://github.com/${GITHUB_USER}.keys"
SSH_DIR="${HOME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

fetch_keys() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${KEYS_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "${KEYS_URL}"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
}

keys="$(fetch_keys | awk '/^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) /')"
if [[ -z "${keys}" ]]; then
  echo "No supported public key found at ${KEYS_URL}" >&2
  exit 1
fi

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${AUTHORIZED_KEYS}"
chmod 600 "${AUTHORIZED_KEYS}"

installed=0
while IFS= read -r key; do
  [[ -n "${key}" ]] || continue
  if ! grep -qxF "${key}" "${AUTHORIZED_KEYS}"; then
    printf '%s\n' "${key}" >> "${AUTHORIZED_KEYS}"
    installed=$((installed + 1))
  fi
done <<< "${keys}"

echo "Installed ${installed} new key(s) for ${GITHUB_USER}."
echo "Authorized keys: ${AUTHORIZED_KEYS}"
