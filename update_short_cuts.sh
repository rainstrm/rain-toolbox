#!/usr/bin/env bash
set -euo pipefail

# Replace a local short_cuts checkout with a freshly cloned copy.
# Override defaults with SHORT_CUTS_REPO and SHORT_CUTS_DIR.

REPO_URL="${SHORT_CUTS_REPO:-git@github-rain:rain-strom/short_cuts.git}"
TARGET_DIR="${SHORT_CUTS_DIR:-${PWD}/short_cuts}"
PARENT_DIR="$(dirname "${TARGET_DIR}")"
TARGET_NAME="$(basename "${TARGET_DIR}")"
TMP_DIR="${PARENT_DIR}/.${TARGET_NAME}.update.$$"
BACKUP_DIR=""

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

command -v git >/dev/null 2>&1 || {
  echo "git is required" >&2
  exit 1
}

mkdir -p "${PARENT_DIR}"
echo "Cloning ${REPO_URL}..."
git clone "${REPO_URL}" "${TMP_DIR}"

if [[ -e "${TARGET_DIR}" || -L "${TARGET_DIR}" ]]; then
  BACKUP_DIR="${TARGET_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
  echo "Backing up existing directory to ${BACKUP_DIR}"
  mv "${TARGET_DIR}" "${BACKUP_DIR}"
fi

if ! mv "${TMP_DIR}" "${TARGET_DIR}"; then
  if [[ -n "${BACKUP_DIR}" && -e "${BACKUP_DIR}" ]]; then
    mv "${BACKUP_DIR}" "${TARGET_DIR}"
  fi
  echo "Update failed; the previous directory was restored." >&2
  exit 1
fi
trap - EXIT

if [[ -f "${TARGET_DIR}/expand/get_running_python.sh" ]]; then
  chmod +x "${TARGET_DIR}/expand/get_running_python.sh"
fi

echo "Updated: ${TARGET_DIR}"
[[ -z "${BACKUP_DIR}" ]] || echo "Previous version: ${BACKUP_DIR}"
