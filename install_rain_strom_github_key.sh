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

available_keys=()
while IFS= read -r key; do
  available_keys+=("${key}")
done < <(fetch_keys | awk '/^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) / && !seen[$0]++')

if (( ${#available_keys[@]} == 0 )); then
  echo "No supported public key found at ${KEYS_URL}" >&2
  exit 1
fi

describe_key() {
  local key="$1"
  local key_type key_data comment fingerprint

  read -r key_type key_data comment <<< "${key}"
  fingerprint=""
  if command -v ssh-keygen >/dev/null 2>&1; then
    fingerprint="$(printf '%s\n' "${key}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)"
  fi

  [[ -n "${fingerprint}" ]] || fingerprint="fingerprint unavailable"
  [[ -n "${comment:-}" ]] || comment="no comment"
  printf '%s | %s | %s' "${key_type}" "${fingerprint}" "${comment}"
}

echo "Public SSH keys for ${GITHUB_USER}:"
for index in "${!available_keys[@]}"; do
  printf '  [%d] ' "$((index + 1))"
  describe_key "${available_keys[index]}"
  printf '\n'
done

declare -a selected_keys=()
selection="${KEY_SELECTION:-}"

if (( ${#available_keys[@]} > 1 )) && [[ -z "${selection}" && -t 0 ]]; then
  printf 'Select key number(s), separated by spaces or commas [all]: '
  read -r selection || selection=""
fi

case "${selection}" in
  ""|a|A|all|ALL|All)
    selected_keys=("${available_keys[@]}")
    ;;
  *)
    selection="${selection//,/ }"
    requested_numbers=()
    selected_index_list=" "
    read -r -a requested_numbers <<< "${selection}"
    for number in "${requested_numbers[@]}"; do
      if [[ ! "${number}" =~ ^[0-9]+$ ]] \
        || (( 10#${number} < 1 || 10#${number} > ${#available_keys[@]} )); then
        echo "Invalid key number: ${number}" >&2
        echo "Choose from 1 to ${#available_keys[@]}, or press Enter for all keys." >&2
        exit 1
      fi

      index=$((10#${number} - 1))
      candidate_key="${available_keys[index]}"
      if [[ "${selected_index_list}" != *" ${index} "* ]]; then
        selected_keys+=("${candidate_key}")
        selected_index_list+="${index} "
      fi
    done

    if (( ${#selected_keys[@]} == 0 )); then
      echo "No key selected." >&2
      exit 1
    fi
    ;;
esac

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${AUTHORIZED_KEYS}"
chmod 600 "${AUTHORIZED_KEYS}"

installed=0
existing=0
for key in "${selected_keys[@]}"; do
  if ! grep -qxF "${key}" "${AUTHORIZED_KEYS}"; then
    printf '%s\n' "${key}" >> "${AUTHORIZED_KEYS}"
    installed=$((installed + 1))
  else
    existing=$((existing + 1))
  fi
done

echo "Selected ${#selected_keys[@]} key(s): ${installed} installed, ${existing} already present."
echo "Authorized keys: ${AUTHORIZED_KEYS}"
