#!/usr/bin/env bash
set -euo pipefail

# Update short_cuts, fix required permissions, and install Python dependencies.
# The existing directory is backed up first, and local sensitive files
# (.env, web/data/auth.json) are restored into the fresh clone.
# Optional overrides:
#   SHORT_CUTS_REPO, SHORT_CUTS_DIR, SHORT_CUTS_BRANCH, GITHUB_HOST_ALIAS
#   Existing git checkouts are updated in place (git fetch + reset), so
#   untracked runtime state such as logs/ and .env stays untouched and
#   running scripts keep writing to the same paths.
#   INSTALL_REQUIREMENTS=0  Skip Python dependency installation.
#   PRESERVE_FILES          Space-separated paths restored from the old copy
#                           (default: .env web/data/auth.json).
#   AUTH_BACKUP_FILE        Persistent copy of web/data/auth.json that survives
#                           even if the timestamped backup is deleted
#                           (e.g. /root/auth.json on servers; empty = disabled).
#   RESTART_WEB_SERVICE=1   Restart the web console after the update.
#   WEB_SERVER_SCRIPT       Path to the web entrypoint
#                           (default: ${TARGET_DIR}/web/server.py).
#   WEB_SERVER_PORT         Port of the web console (default: 4188).
#   LOG_PURGE=0             Skip the stale-log cleanup (default: enabled).
#   LOG_DIR                 Directory cleaned as the first step
#                           (default: ${HOME}/logs).
#   LOG_KEEP_DAYS           Keep logs modified within N days (default: 3).

REPO_URL="${SHORT_CUTS_REPO:-git@github-rain:rainstrm/short_cuts.git}"
TARGET_DIR="${SHORT_CUTS_DIR:-${PWD}/short_cuts}"
SSH_HOST="${GITHUB_HOST_ALIAS:-github-rain}"
INSTALL_REQUIREMENTS="${INSTALL_REQUIREMENTS:-1}"
PRESERVE_FILES="${PRESERVE_FILES:-.env web/data/auth.json}"
PARENT_DIR="$(dirname "${TARGET_DIR}")"
TARGET_NAME="$(basename "${TARGET_DIR}")"
TMP_DIR="${PARENT_DIR}/.${TARGET_NAME}.update.$$"
BACKUP_DIR=""
RESTORE_LIST=()
AUTH_BACKUP_FILE="${AUTH_BACKUP_FILE:-}"
SHORT_CUTS_BRANCH="${SHORT_CUTS_BRANCH:-main}"
RESTART_WEB_SERVICE="${RESTART_WEB_SERVICE:-0}"
WEB_SERVER_SCRIPT="${WEB_SERVER_SCRIPT:-${TARGET_DIR}/web/server.py}"
WEB_SERVER_PORT="${WEB_SERVER_PORT:-4188}"
LOG_PURGE="${LOG_PURGE:-1}"
LOG_DIR="${LOG_DIR:-${HOME}/logs}"
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-3}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== short_cuts updater ==="

# ==================== Step 1: purge stale logs ====================
# Ported from upstream rmbbiji/rmbbiji-toolbox: drop log files older than
# LOG_KEEP_DAYS from ~/logs before the repository is touched, so a long-running
# box does not fill its disk with old trading logs. Only regular files are
# removed (-type f), so the directory layout itself always survives, and any
# permission/IO error is reported without aborting the whole update.
case "${LOG_PURGE}" in
  0|false|FALSE|no|NO)
    echo "Stale log cleanup skipped (LOG_PURGE=${LOG_PURGE})."
    ;;
  *)
    echo "Purging files older than ${LOG_KEEP_DAYS} days from ${LOG_DIR}..."
    if [[ -d "${LOG_DIR}" ]]; then
      # find -mtime +N means "modified more than N*24h ago" and also matches
      # part of day N+1. For an exact N*24h cutoff use -mmin +$((N*24*60)).
      stale_logs="$(
        { find "${LOG_DIR}" -type f -mtime "+${LOG_KEEP_DAYS}" 2>/dev/null || true; } | wc -l | tr -d ' '
      )"
      if [[ "${stale_logs}" -gt 0 ]]; then
        find "${LOG_DIR}" -type f -mtime "+${LOG_KEEP_DAYS}" -delete 2>/dev/null || true
        remaining_logs="$(
          { find "${LOG_DIR}" -type f 2>/dev/null || true; } | wc -l | tr -d ' '
        )"
        echo "Removed ${stale_logs} file(s) older than ${LOG_KEEP_DAYS} days; ${remaining_logs} left."
      else
        echo "No file older than ${LOG_KEEP_DAYS} days; nothing to purge."
      fi
    else
      echo "Log directory does not exist; skipping cleanup: ${LOG_DIR}"
    fi
    ;;
esac

command -v git >/dev/null 2>&1 || { echo "git is required but was not found." >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required but was not found." >&2; exit 1; }

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

  if [[ -d "${TARGET_DIR}/.git" ]]; then
    # In-place update: the directory inode stays the same and untracked
    # runtime state (logs/, .env, web/data/auth.json) is never moved, so
    # running trading scripts keep logging to the same paths.
    echo "In-place update (existing git checkout): ${TARGET_DIR}"

    if ! git -C "${TARGET_DIR}" remote get-url origin >/dev/null 2>&1; then
      git -C "${TARGET_DIR}" remote add origin "${REPO_URL}"
    elif [[ "$(git -C "${TARGET_DIR}" remote get-url origin)" != "${REPO_URL}" ]]; then
      git -C "${TARGET_DIR}" remote set-url origin "${REPO_URL}"
    fi

    if git -C "${TARGET_DIR}" fetch origin --prune; then
      git -C "${TARGET_DIR}" branch -f update-backup HEAD
      git -C "${TARGET_DIR}" reset --hard "origin/${SHORT_CUTS_BRANCH}"
      echo "Repository updated in place; previous HEAD saved to branch 'update-backup'."
    else
      echo "git fetch failed; continuing with local version: ${TARGET_DIR}" >&2
    fi
  else
    if git clone "${REPO_URL}" "${TMP_DIR}"; then
      # Record local files that should survive the update (present in the old copy).
      if [[ -d "${TARGET_DIR}" ]]; then
        for item in ${PRESERVE_FILES}; do
          if [[ -e "${TARGET_DIR}/${item}" ]]; then
            RESTORE_LIST+=("${item}")
          fi
        done
      fi

      # Persist a copy of the web auth file at a stable path so it survives even
      # if the timestamped backup is deleted (e.g. /root/auth.json on servers).
      if [[ -n "${AUTH_BACKUP_FILE}" && -f "${TARGET_DIR}/web/data/auth.json" ]]; then
        if [[ -f "${AUTH_BACKUP_FILE}" ]]; then
          echo "Auth backup already exists; keeping it: ${AUTH_BACKUP_FILE}"
        else
          mkdir -p "$(dirname "${AUTH_BACKUP_FILE}")"
          cp "${TARGET_DIR}/web/data/auth.json" "${AUTH_BACKUP_FILE}"
          echo "Backed up web auth file to ${AUTH_BACKUP_FILE}"
        fi
      fi

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

      # Restore local secrets right away, before anything else can fail: the
      # web console then keeps its auth.json even if dependency installation
      # aborts the script later on.
      if [[ -n "${BACKUP_DIR}" && ${#RESTORE_LIST[@]} -gt 0 ]]; then
        for item in "${RESTORE_LIST[@]}"; do
          mkdir -p "$(dirname "${TARGET_DIR}/${item}")"
          cp -a "${BACKUP_DIR}/${item}" "${TARGET_DIR}/${item}"
          echo "Restored local file: ${item}"
        done
      fi

      # Fall back to the persistent auth backup when the old copy had none;
      # the web service (if restarted below) then starts with auth in place.
      if [[ -n "${AUTH_BACKUP_FILE}" && -f "${AUTH_BACKUP_FILE}" && ! -f "${TARGET_DIR}/web/data/auth.json" ]]; then
        mkdir -p "$(dirname "${TARGET_DIR}/web/data/auth.json")"
        cp -f "${AUTH_BACKUP_FILE}" "${TARGET_DIR}/web/data/auth.json"
        echo "Restored web auth file from ${AUTH_BACKUP_FILE}"
      fi

      echo "Repository updated: ${TARGET_DIR}"
      [[ -z "${BACKUP_DIR}" ]] || echo "Previous version: ${BACKUP_DIR}"
    elif [[ -d "${TARGET_DIR}" ]]; then
      echo "Repository clone failed; continuing with local version: ${TARGET_DIR}" >&2
    else
      echo "Repository clone failed and no local version exists: ${TARGET_DIR}" >&2
      exit 1
    fi
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

      # --ignore-installed is required, not cosmetic:
      # lighter-sdk>=1.1.4 pins urllib3<2.1.0, so pip wants urllib3 2.0.7. On
      # Debian the system already has urllib3 2.3.0 installed by apt
      # (python3-urllib3) under /usr/lib/python3/dist-packages, which has no
      # RECORD file; pip then aborts the whole run with uninstall-no-record-file
      # while trying to uninstall it. With --ignore-installed pip only writes to
      # /usr/local dist-packages (ahead of /usr/lib/python3/dist-packages in
      # sys.path) and never tries to touch the apt-managed package.
      pip_args=(
        install
        --upgrade
        --ignore-installed
        --disable-pip-version-check
        -r "${REQUIREMENTS_FILE}"
      )

      # Debian 12+ may reject system installs unless this supported flag is supplied.
      if python3 -m pip install --help 2>&1 | grep -q -- "--break-system-packages"; then
        pip_args+=(--break-system-packages)
      fi

      echo "Installing or updating Python dependencies from ${REQUIREMENTS_FILE}..."
      if ! python3 -m pip "${pip_args[@]}"; then
        echo "Python dependency installation failed." >&2
        echo "If it still reports uninstall-no-record-file, run the same command manually to see the full log:" >&2
        echo "  python3 -m pip install --upgrade --ignore-installed --break-system-packages -r ${REQUIREMENTS_FILE}" >&2
        exit 1
      fi
      # lighter-sdk needs urllib3<2.1; print the version actually in effect so it
      # is obvious whether the apt-managed 2.3.0 won or not.
      python3 -c "import urllib3; print('urllib3', urllib3.__version__, urllib3.__file__)" || true
      echo "Python dependencies are up to date."
    fi
    ;;
esac

case "${RESTART_WEB_SERVICE}" in
  0|false|FALSE|no|NO)
    echo "Web service restart skipped (RESTART_WEB_SERVICE=${RESTART_WEB_SERVICE})."
    ;;
  *)
    if [[ ! -f "${WEB_SERVER_SCRIPT}" ]]; then
      echo "Web service script not found: ${WEB_SERVER_SCRIPT}" >&2
      exit 1
    fi
    command -v lsof >/dev/null 2>&1 || {
      echo "lsof is required to restart the web service." >&2
      exit 1
    }

    get_server_pids() {
      # Processes listening on the web port; works on both Linux and macOS.
      lsof -ti "tcp:${WEB_SERVER_PORT}" -sTCP:LISTEN 2>/dev/null || true
    }

    # Local secrets were restored immediately after the clone/move above, so the
    # old service can be stopped right away.
    echo "Stopping the old short_cuts web service..."
    server_pids="$(get_server_pids)"
    if [[ -n "${server_pids}" ]]; then
      for pid in ${server_pids}; do
        kill "${pid}" 2>/dev/null || true
      done

      # Give the service a moment to exit so the port is free for the new one.
      sleep 1
      remaining_pids="$(get_server_pids)"
      if [[ -n "${remaining_pids}" ]]; then
        echo "Old service did not exit; force stopping..."
        for pid in ${remaining_pids}; do
          kill -KILL "${pid}" 2>/dev/null || true
        done
        sleep 1
        remaining_pids="$(get_server_pids)"
        if [[ -n "${remaining_pids}" ]]; then
          echo "Unable to stop the old web service: ${remaining_pids}" >&2
          exit 1
        fi
      fi
      echo "Old web service stopped."
    else
      echo "No running web service found."
    fi

    echo "Starting the new short_cuts web service..."
    nohup python3 "${WEB_SERVER_SCRIPT}" --host 0.0.0.0 --port "${WEB_SERVER_PORT}" >/dev/null 2>&1 &
    server_pid=$!
    sleep 1
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      echo "Web service failed to start." >&2
      exit 1
    fi
    echo "Web service started (PID: ${server_pid}, port: ${WEB_SERVER_PORT})."
    ;;
esac

echo "short_cuts update completed."
