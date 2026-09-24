#!/usr/bin/env bash
set -euo pipefail

# Update short_cuts, fix required permissions, and install Python dependencies,
# using whichever GitHub credential this server happens to have.
#
# Credentials are tried in this order, and the first usable one wins:
#   1. personal key   ${GITHUB_SSH_KEY:-$HOME/.ssh/id_rsa}             git over SSH
#   2. deploy key     ${DEPLOY_KEY:-$HOME/.ssh/deploy_key_shortcuts}   git over SSH, read-only
#   3. no usable key  repository archive over HTTPS                    files overwritten in place
#
# (2) is for servers that must not hold the personal key: a deploy key is scoped
# to short_cuts alone and is read-only, so that server can fetch but never push.
# (3) needs no credential at all - it downloads the repository archive and
# copies the files over the existing tree, which leaves untracked runtime state
# (logs/, .env, web/data/auth.json) exactly where it is. A private repository
# needs GITHUB_TOKEN (or GH_TOKEN) for that download.
#
# Both SSH transports pass the key explicitly (-i plus IdentitiesOnly=yes), so
# no Host alias in ~/.ssh/config is required and setup_github_ssh.sh is no
# longer a prerequisite; an alias still works if GITHUB_HOST_ALIAS is set.
#
# The existing directory is backed up first, and local sensitive files
# (.env, web/data/auth.json) are restored into the fresh clone.
# Optional overrides:
#   SHORT_CUTS_DIR, SHORT_CUTS_BRANCH, SHORT_CUTS_SLUG, SHORT_CUTS_REPO
#   GITHUB_SSH_KEY, DEPLOY_KEY, GITHUB_HOST_ALIAS, DEPLOY_HOST_ALIAS
#   SHORT_CUTS_ARCHIVE      Archive URL, or a path to a pre-staged archive.
#   GITHUB_TOKEN/GH_TOKEN   Read token used only for the archive download.
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

SHORT_CUTS_SLUG="${SHORT_CUTS_SLUG:-rainstrm/short_cuts}"
SHORT_CUTS_BRANCH="${SHORT_CUTS_BRANCH:-main}"
TARGET_DIR="${SHORT_CUTS_DIR:-${PWD}/short_cuts}"
PERSONAL_KEY="${GITHUB_SSH_KEY:-${HOME}/.ssh/id_rsa}"
DEPLOY_KEY="${DEPLOY_KEY:-${HOME}/.ssh/deploy_key_shortcuts}"
GITHUB_HOST="${GITHUB_HOST_ALIAS:-github.com}"
DEPLOY_HOST="${DEPLOY_HOST_ALIAS:-github.com}"
ARCHIVE_SOURCE="${SHORT_CUTS_ARCHIVE:-https://codeload.github.com/${SHORT_CUTS_SLUG}/tar.gz/refs/heads/${SHORT_CUTS_BRANCH}}"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
INSTALL_REQUIREMENTS="${INSTALL_REQUIREMENTS:-1}"
PRESERVE_FILES="${PRESERVE_FILES:-.env web/data/auth.json}"
PARENT_DIR="$(dirname "${TARGET_DIR}")"
TARGET_NAME="$(basename "${TARGET_DIR}")"
TMP_DIR="${PARENT_DIR}/.${TARGET_NAME}.update.$$"
ARCHIVE_FILE="${TMP_DIR}.tar.gz"
PRESERVE_DIR="${TMP_DIR}.preserve"
BACKUP_DIR=""
RESTORE_LIST=()
AUTH_BACKUP_FILE="${AUTH_BACKUP_FILE:-}"
RESTART_WEB_SERVICE="${RESTART_WEB_SERVICE:-0}"
WEB_SERVER_SCRIPT="${WEB_SERVER_SCRIPT:-${TARGET_DIR}/web/server.py}"
WEB_SERVER_PORT="${WEB_SERVER_PORT:-4188}"
LOG_PURGE="${LOG_PURGE:-1}"
LOG_DIR="${LOG_DIR:-${HOME}/logs}"
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-3}"

cleanup() {
  rm -rf "${TMP_DIR}" "${ARCHIVE_FILE}" "${PRESERVE_DIR}"
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

mkdir -p "${PARENT_DIR}"

have() { command -v "$1" >/dev/null 2>&1; }

active_key=""
active_host=""
git_url=""

# Confirm that GitHub accepts this key. The test host is the bare GitHub host by
# default, so the answer depends only on the key and not on ~/.ssh/config;
# GitHub prints the greeting on stderr and returns non-zero even on success.
ssh_key_accepted() {
  local key="$1" host="$2" output=""
  output="$(
    ssh \
      -i "${key}" \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o ConnectTimeout=12 \
      -o StrictHostKeyChecking=accept-new \
      -T "git@${host}" 2>&1 || true
  )"
  printf '%s\n' "${output}" | grep -qi "successfully authenticated"
}

# ==================== Step 2: pick a credential ====================
# Tier 1 and tier 2 are identical apart from the key path, because both only
# need read access; the deploy key simply cannot push, which is the point.
if have ssh && [[ -f "${PERSONAL_KEY}" ]]; then
  echo "Found personal GitHub key: ${PERSONAL_KEY}"
  if ssh_key_accepted "${PERSONAL_KEY}" "${GITHUB_HOST}"; then
    active_key="${PERSONAL_KEY}"
    active_host="${GITHUB_HOST}"
    git_url="${SHORT_CUTS_REPO:-git@${GITHUB_HOST}:${SHORT_CUTS_SLUG}.git}"
    echo "GitHub accepted the personal key; updating over SSH."
  else
    echo "GitHub rejected the personal key (revoked, or not added to the account); trying the next credential." >&2
  fi
elif have ssh; then
  echo "Personal GitHub key not found: ${PERSONAL_KEY}"
fi

if [[ -z "${active_key}" ]] && have ssh && [[ -f "${DEPLOY_KEY}" ]]; then
  echo "Found short_cuts deploy key: ${DEPLOY_KEY}"
  if ssh_key_accepted "${DEPLOY_KEY}" "${DEPLOY_HOST}"; then
    active_key="${DEPLOY_KEY}"
    active_host="${DEPLOY_HOST}"
    git_url="${SHORT_CUTS_REPO:-git@${DEPLOY_HOST}:${SHORT_CUTS_SLUG}.git}"
    echo "GitHub accepted the deploy key; updating over SSH (read-only)."
  else
    echo "GitHub rejected the deploy key." >&2
    echo "Add this public key under Settings > Deploy keys > Add deploy key (read-only):" >&2
    if [[ -f "${DEPLOY_KEY}.pub" ]]; then
      echo "----------------------------------------" >&2
      cat "${DEPLOY_KEY}.pub" >&2
      echo "----------------------------------------" >&2
    else
      echo "  (public key not found: ${DEPLOY_KEY}.pub)" >&2
    fi
    echo "Falling back to the archive download." >&2
  fi
elif [[ -z "${active_key}" ]] && have ssh; then
  echo "Deploy key not found: ${DEPLOY_KEY}"
fi

if [[ -z "${active_key}" ]]; then
  echo "No usable GitHub key; falling back to the HTTPS archive update."
fi

# ==================== Step 3: install from a prepared tree ====================
# Shared by the git clone and the archive download: the prepared tree sits in
# TMP_DIR and replaces TARGET_DIR, which is backed up first.
install_prepared_tree() {
  local item=""

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

  # Restore local secrets right away, before anything else can fail: the web
  # console then keeps its auth.json even if dependency installation aborts the
  # script later on.
  if [[ -n "${BACKUP_DIR}" && ${#RESTORE_LIST[@]} -gt 0 ]]; then
    for item in "${RESTORE_LIST[@]}"; do
      mkdir -p "$(dirname "${TARGET_DIR}/${item}")"
      cp -a "${BACKUP_DIR}/${item}" "${TARGET_DIR}/${item}"
      echo "Restored local file: ${item}"
    done
  fi

  # Fall back to the persistent auth backup when the old copy had none; the web
  # service (if restarted below) then starts with auth in place.
  if [[ -n "${AUTH_BACKUP_FILE}" && -f "${AUTH_BACKUP_FILE}" && ! -f "${TARGET_DIR}/web/data/auth.json" ]]; then
    mkdir -p "$(dirname "${TARGET_DIR}/web/data/auth.json")"
    cp -f "${AUTH_BACKUP_FILE}" "${TARGET_DIR}/web/data/auth.json"
    echo "Restored web auth file from ${AUTH_BACKUP_FILE}"
  fi

  echo "Repository updated: ${TARGET_DIR}"
  [[ -z "${BACKUP_DIR}" ]] || echo "Previous version: ${BACKUP_DIR}"
}

# ==================== Step 4a: update over SSH ====================
update_from_git() {
  local repo_url="$1" key="$2" host="$3"

  if ! have git; then
    echo "git is required for the SSH update but was not found." >&2
    if [[ -d "${TARGET_DIR}" ]]; then
      echo "Continuing with the local version: ${TARGET_DIR}" >&2
      return 0
    fi
    return 1
  fi

  # Pin the identity: without IdentitiesOnly the agent or ~/.ssh/config could
  # offer a different key first and the deploy-key server would fail for a
  # reason that has nothing to do with this key.
  GIT_SSH_COMMAND="ssh -i ${key} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  export GIT_SSH_COMMAND

  if [[ -d "${TARGET_DIR}/.git" ]]; then
    # In-place update: the directory inode stays the same and untracked
    # runtime state (logs/, .env, web/data/auth.json) is never moved, so
    # running trading scripts keep logging to the same paths.
    echo "In-place update (existing git checkout): ${TARGET_DIR}"

    if ! git -C "${TARGET_DIR}" remote get-url origin >/dev/null 2>&1; then
      git -C "${TARGET_DIR}" remote add origin "${repo_url}"
    elif [[ "$(git -C "${TARGET_DIR}" remote get-url origin)" != "${repo_url}" ]]; then
      # A deployment made when this server held the other key still points at
      # that key's host; without this it would keep looking for a key that was
      # deliberately removed here.
      echo "Repointing origin at ${host} (this server's credential)."
      git -C "${TARGET_DIR}" remote set-url origin "${repo_url}"
    fi

    if git -C "${TARGET_DIR}" fetch origin --prune; then
      git -C "${TARGET_DIR}" branch -f update-backup HEAD
      git -C "${TARGET_DIR}" reset --hard "origin/${SHORT_CUTS_BRANCH}"
      echo "Repository updated in place; previous HEAD saved to branch 'update-backup'."
    else
      echo "git fetch failed; continuing with local version: ${TARGET_DIR}" >&2
    fi
    return 0
  fi

  if git clone --branch "${SHORT_CUTS_BRANCH}" "${repo_url}" "${TMP_DIR}"; then
    install_prepared_tree
    return 0
  fi

  if [[ -d "${TARGET_DIR}" ]]; then
    echo "Repository clone failed; continuing with local version: ${TARGET_DIR}" >&2
    return 0
  fi
  echo "Repository clone failed and no local version exists: ${TARGET_DIR}" >&2
  return 1
}

# ==================== Step 4b: update from an archive ====================
download_archive() {
  local url="$1" out="$2"

  # The existence of a file is what decides success, not the exit status of the
  # downloader: an empty or missing file must never be handed to tar, otherwise
  # a 404 page would be extracted over a working deployment. curl keeps the
  # reason on stderr (-S), and a failure here falls through to wget, which can
  # still work behind a proxy that blocks one of them.
  if have curl; then
    rm -f "${out}"
    if [[ -n "${GITHUB_TOKEN}" ]]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -o "${out}" "${url}" || true
    else
      curl -fsSL -o "${out}" "${url}" || true
    fi
    if [[ -s "${out}" ]]; then
      return 0
    fi
  fi

  if have wget; then
    rm -f "${out}"
    if [[ -n "${GITHUB_TOKEN}" ]]; then
      wget -q --header="Authorization: Bearer ${GITHUB_TOKEN}" -O "${out}" "${url}" || true
    else
      wget -q -O "${out}" "${url}" || true
    fi
    if [[ -s "${out}" ]]; then
      return 0
    fi
  fi

  if ! have curl && ! have wget; then
    echo "curl or wget is required to download the archive." >&2
  fi
  return 1
}

# Copy the downloaded tree over the existing directory instead of replacing it.
# The directory itself is never moved, so a running script keeps its open log
# path and untracked state survives.
overwrite_target_in_place() {
  local item="" relative=""

  echo "Overwriting repository files in place: ${TARGET_DIR}"

  # The archive only carries tracked files, so .env, logs/ and
  # web/data/auth.json are not touched by the copy. PRESERVE_FILES is
  # snapshotted anyway, so this stays correct if the repository ever starts
  # shipping one of those names.
  mkdir -p "${PRESERVE_DIR}"
  for item in ${PRESERVE_FILES}; do
    if [[ -e "${TARGET_DIR}/${item}" ]]; then
      mkdir -p "$(dirname "${PRESERVE_DIR}/${item}")"
      cp -a "${TARGET_DIR}/${item}" "${PRESERVE_DIR}/${item}"
    fi
  done

  # Without a fetch there is no new commit to diff against, so use the commit
  # this checkout is already on: a file tracked there but absent from the
  # archive was deleted upstream and must not survive as a leftover.
  if have git && [[ -d "${TARGET_DIR}/.git" ]]; then
    while IFS= read -r relative; do
      if [[ -n "${relative}" && ! -e "${TMP_DIR}/${relative}" && -e "${TARGET_DIR}/${relative}" ]]; then
        rm -f "${TARGET_DIR}/${relative}"
        echo "Removed file no longer in the repository: ${relative}"
      fi
    done < <(git -C "${TARGET_DIR}" ls-tree -r --name-only HEAD 2>/dev/null || true)
  fi

  if ! cp -a "${TMP_DIR}/." "${TARGET_DIR}/"; then
    echo "Overwriting the repository files failed." >&2
    return 1
  fi

  for item in ${PRESERVE_FILES}; do
    if [[ -e "${PRESERVE_DIR}/${item}" ]]; then
      mkdir -p "$(dirname "${TARGET_DIR}/${item}")"
      cp -a "${PRESERVE_DIR}/${item}" "${TARGET_DIR}/${item}"
      echo "Restored local file: ${item}"
    fi
  done
  rm -rf "${PRESERVE_DIR}"

  if [[ -n "${AUTH_BACKUP_FILE}" && -f "${AUTH_BACKUP_FILE}" && ! -f "${TARGET_DIR}/web/data/auth.json" ]]; then
    mkdir -p "$(dirname "${TARGET_DIR}/web/data/auth.json")"
    cp -f "${AUTH_BACKUP_FILE}" "${TARGET_DIR}/web/data/auth.json"
    echo "Restored web auth file from ${AUTH_BACKUP_FILE}"
  fi

  echo "Repository files overwritten: ${TARGET_DIR}"
  echo "This transport has no git metadata to compare with; files removed upstream are handled via the"
  echo "commit already checked out, if any. Restore the key and rerun to get a normal git update."
}

update_from_archive() {
  if ! have tar; then
    echo "tar is required for the archive update but was not found." >&2
    return 1
  fi

  echo "Archive source: ${ARCHIVE_SOURCE}"
  if [[ "${ARCHIVE_SOURCE}" =~ ^https?:// ]]; then
    if [[ -z "${GITHUB_TOKEN}" ]]; then
      echo "No GITHUB_TOKEN set; the download only works for a public repository." >&2
    fi
    if ! download_archive "${ARCHIVE_SOURCE}" "${ARCHIVE_FILE}"; then
      echo "Archive download failed: ${ARCHIVE_SOURCE}" >&2
      if [[ -d "${TARGET_DIR}" ]]; then
        echo "Continuing with the local version: ${TARGET_DIR}" >&2
        return 0
      fi
      echo "No local version to fall back on." >&2
      return 1
    fi
  else
    # A path to an archive that was staged on the server beforehand.
    if [[ ! -f "${ARCHIVE_SOURCE}" ]]; then
      echo "Archive not found: ${ARCHIVE_SOURCE}" >&2
      return 1
    fi
    cp -f "${ARCHIVE_SOURCE}" "${ARCHIVE_FILE}"
  fi

  mkdir -p "${TMP_DIR}"
  # codeload tarballs wrap everything in a single "<repo>-<ref>/" directory.
  if ! tar -xzf "${ARCHIVE_FILE}" -C "${TMP_DIR}" --strip-components=1; then
    echo "Archive extraction failed: ${ARCHIVE_FILE}" >&2
    if [[ -d "${TARGET_DIR}" ]]; then
      echo "Continuing with the local version: ${TARGET_DIR}" >&2
      return 0
    fi
    return 1
  fi

  if [[ -z "$(ls -A "${TMP_DIR}")" ]]; then
    echo "Archive extracted to an empty tree; refusing to update." >&2
    return 1
  fi

  if [[ -e "${TARGET_DIR}" ]]; then
    overwrite_target_in_place
  else
    install_prepared_tree
  fi
}

if [[ -n "${active_key}" ]]; then
  update_from_git "${git_url}" "${active_key}" "${active_host}"
else
  update_from_archive
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
