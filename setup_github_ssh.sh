#!/usr/bin/env bash
set -euo pipefail

# Configure an isolated GitHub host alias for the rain-strom account.
# The private key is referenced in place and is never copied.

SSH_DIR="${HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"
KEY_PATH="${GITHUB_SSH_KEY:-${SSH_DIR}/id_rsa}"
HOST_ALIAS="${GITHUB_HOST_ALIAS:-github-rain}"
MANAGED_BEGIN="# >>> rain-toolbox ${HOST_ALIAS} >>>"
MANAGED_END="# <<< rain-toolbox ${HOST_ALIAS} <<<"

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "SSH private key not found: ${KEY_PATH}" >&2
  exit 1
fi

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chmod 600 "${KEY_PATH}"
touch "${SSH_CONFIG}"
chmod 600 "${SSH_CONFIG}"

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

awk -v begin="${MANAGED_BEGIN}" -v end="${MANAGED_END}" '
  $0 == begin { managed=1; next }
  $0 == end { managed=0; next }
  managed != 1 { print }
' "${SSH_CONFIG}" > "${tmp_file}"

cat >> "${tmp_file}" <<EOF

${MANAGED_BEGIN}
Host ${HOST_ALIAS}
  HostName github.com
  User git
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
${MANAGED_END}
EOF

mv "${tmp_file}" "${SSH_CONFIG}"
chmod 600 "${SSH_CONFIG}"
trap - EXIT

echo "Configured GitHub SSH alias: ${HOST_ALIAS}"
echo "Test it with: ssh -T git@${HOST_ALIAS}"
echo "Clone with: git clone git@${HOST_ALIAS}:rain-strom/REPOSITORY.git"
