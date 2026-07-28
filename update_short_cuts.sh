#!/usr/bin/env bash
set -euo pipefail

# Update short_cuts, fix required permissions, and install Python dependencies.
# Optional overrides:
#   SHORT_CUTS_REPO, SHORT_CUTS_DIR, GITHUB_HOST_ALIAS
#   INSTALL_REQUIREMENTS=0  Skip Python dependency installation.

REPO_URL="${SHORT_CUTS_REPO:-git@github-rain:rainstrm/short_cuts.git}"
TARGET_DIR="${SHORT_CUTS_DIR:-${PWD}/short_cuts}"
SSH_HOST="${GITHUB_HOST_ALIAS:-github-rain}"
INSTALL_REQUIREMENTS="${INSTALL_REQUIREMENTS:-1}"
PARENT_DIR="$(dirname "${TARGET_DIR}")"
TARGET_NAME="$(basename "${TARGET_DIR}")"
TMP_DIR="${PARENT_DIR}/.${TARGET_NAME}.update.$$"
BACKUP_DIR=""

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== short_cuts updater ==="

command -v git >/dev/null 2>&1 || {
  echo "git is required but was not found." >&2
  exit 1
}

command -v ssh >/dev/null 2>&1 || {
  echo "ssh is required but was not found." >&2
  exit 1
}

mkdir -p "${PARENT_DIR}"

echo "Checking GitHub SSH access through ${SSH_HOST}..."
# GitHub reports successful authentication but intentionally returns a non-zero status.
ssh_output="$(
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=12 \
    -o StrictHostKeyChecking=accept-new \
    -T "${SSH_HOST}" 2>&1 || true
)"

if printf '%s\n' "${ssh_output}" | grep -qi "successfully authenticated"; then
  echo "GitHub SSH authentication succeeded. Updating repository..."

  if git clone "${REPO_URL}" "${TMP_DIR}"; then
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

    echo "Repository updated: ${TARGET_DIR}"
    [[ -z "${BACKUP_DIR}" ]] || echo "Previous version: ${BACKUP_DIR}"
  elif [[ -d "${TARGET_DIR}" ]]; then
    echo "Repository clone failed; continuing with local version: ${TARGET_DIR}" >&2
  else
    echo "Repository clone failed and no local version exists: ${TARGET_DIR}" >&2
    exit 1
  fi
elif [[ -d "${TARGET_DIR}" ]]; then
  echo "GitHub SSH authentication failed; continuing with local version: ${TARGET_DIR}" >&2
else
  echo "GitHub SSH authentication failed and no local version exists: ${TARGET_DIR}" >&2
  echo "Run setup_github_ssh.sh first, then try again." >&2
  exit 1
fi

echo "Updating executable permissions..."
RUNNING_PYTHON_SCRIPT="${TARGET_DIR}/expand/get_running_python.sh"
if [[ -f "${RUNNING_PYTHON_SCRIPT}" ]]; then
  chmod +x "${RUNNING_PYTHON_SCRIPT}"
  echo "Executable permission set: ${RUNNING_PYTHON_SCRIPT}"
else
  echo "Required script not found: ${RUNNING_PYTHON_SCRIPT}" >&2
  exit 1
fi

REQUIREMENTS_FILE="${TARGET_DIR}/requirements.txt"
case "${INSTALL_REQUIREMENTS}" in
  0|false|FALSE|no|NO)
    echo "Python dependency installation skipped (INSTALL_REQUIREMENTS=${INSTALL_REQUIREMENTS})."
    ;;
  *)
    if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
      echo "requirements.txt not found; skipping dependency installation."
    else
      command -v python3 >/dev/null 2>&1 || {
        echo "python3 is required to install ${REQUIREMENTS_FILE}." >&2
        exit 1
      }

      if ! python3 -m pip --version >/dev/null 2>&1; then
        echo "Python pip is required. Install python3-pip and run this script again." >&2
        exit 1
      fi

      pip_args=(
        install
        --upgrade
        --disable-pip-version-check
        -r "${REQUIREMENTS_FILE}"
      )

      # Debian 12+ may reject system installs unless this supported flag is supplied.
      if python3 -m pip install --help 2>&1 | grep -q -- "--break-system-packages"; then
        pip_args+=(--break-system-packages)
      fi

      echo "Installing or updating Python dependencies from ${REQUIREMENTS_FILE}..."
      python3 -m pip "${pip_args[@]}"
      echo "Python dependencies are up to date."
    fi
    ;;
esac

echo "short_cuts update completed."
