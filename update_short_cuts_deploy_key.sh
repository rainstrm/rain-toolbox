#!/usr/bin/env bash
set -euo pipefail

# Deploy or update short_cuts on a server that must NOT hold rainstrm's personal
# GitHub key. Such a server only gets a read-only deploy key scoped to this one
# repository, so it can pull but can never push anything.
#
# Optional overrides:
#   GITHUB_REPO        Repository to deploy, as owner/name
#                      (default: rainstrm/short_cuts).
#   DEPLOY_KEY         Private deploy key for that repository
#                      (default: ${HOME}/.ssh/deploy_key_shortcuts).
#   DEPLOY_HOST_ALIAS  SSH host alias configured for the deploy key
#                      (default: github.com-deploy-shortcuts).
#   REPO_URL           Full clone URL; bypasses GITHUB_REPO/DEPLOY_HOST_ALIAS.
#   TARGET_DIR         Install directory (default: ${HOME}/short_cuts).
#   BRANCH             Branch to deploy (default: main).
#   SSH_DIR, SSH_CONFIG, KNOWN_HOSTS  Override the SSH file locations.
#
# One-time setup on the server:
#   1. Copy this script and the deploy key to the server, then run:
#        chmod 600 ~/.ssh/deploy_key_shortcuts
#   2. Add the matching public key under the repository's
#      Settings > Deploy keys with read-only access (leave "Allow write
#      access" unchecked).
#   3. Run: bash update_short_cuts_deploy_key.sh

GITHUB_REPO="${GITHUB_REPO:-rainstrm/short_cuts}"
DEPLOY_KEY="${DEPLOY_KEY:-${HOME}/.ssh/deploy_key_shortcuts}"
DEPLOY_HOST_ALIAS="${DEPLOY_HOST_ALIAS:-github.com-deploy-shortcuts}"
REPO_URL="${REPO_URL:-git@${DEPLOY_HOST_ALIAS}:${GITHUB_REPO}.git}"
TARGET_DIR="${TARGET_DIR:-${HOME}/short_cuts}"
BRANCH="${BRANCH:-main}"
SSH_DIR="${SSH_DIR:-${HOME}/.ssh}"
SSH_CONFIG="${SSH_CONFIG:-${SSH_DIR}/config}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${SSH_DIR}/known_hosts}"

command -v git >/dev/null 2>&1 || { echo "git is required but was not found." >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required but was not found." >&2; exit 1; }

echo "=== short_cuts deploy-key deployment ==="

# ---------- 1. The deploy key ----------
if [[ ! -f "${DEPLOY_KEY}" ]]; then
  echo "Deploy key not found: ${DEPLOY_KEY}" >&2
  echo "Copy the private key to that path, then run: chmod 600 ${DEPLOY_KEY}" >&2
  exit 1
fi

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chmod 600 "${DEPLOY_KEY}" 2>/dev/null || true

# ---------- 2. SSH files ----------
# ssh-keygen -F understands both plain and hashed entries, so this stays
# idempotent; grep on a hashed known_hosts (ssh-keyscan -H) never matches and
# would append a fresh copy of the key on every run.
if [[ ! -s "${KNOWN_HOSTS}" ]] \
  || ! ssh-keygen -F github.com -f "${KNOWN_HOSTS}" >/dev/null 2>&1; then
  echo "Adding the github.com host key to ${KNOWN_HOSTS}..."
  if command -v ssh-keyscan >/dev/null 2>&1; then
    scanned_keys="$(ssh-keyscan -H github.com 2>/dev/null || true)"
    if [[ -n "${scanned_keys}" ]]; then
      printf '%s\n' "${scanned_keys}" >> "${KNOWN_HOSTS}"
    else
      echo "Could not fetch the github.com host key; ssh may ask for confirmation." >&2
    fi
  else
    echo "ssh-keyscan is not available; ssh may ask for confirmation." >&2
  fi
else
  echo "github.com is already present in ${KNOWN_HOSTS}."
fi

# Rewrite our own config block in place, so re-running with a different
# DEPLOY_KEY updates the existing entry instead of appending a second one.
MANAGED_BEGIN="# >>> rain-toolbox ${DEPLOY_HOST_ALIAS} >>>"
MANAGED_END="# <<< rain-toolbox ${DEPLOY_HOST_ALIAS} <<<"

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
Host ${DEPLOY_HOST_ALIAS}
  HostName github.com
  User git
  IdentityFile ${DEPLOY_KEY}
  IdentitiesOnly yes
${MANAGED_END}
EOF

mv "${tmp_file}" "${SSH_CONFIG}"
chmod 600 "${SSH_CONFIG}"
trap - EXIT

echo "Configured deploy key host alias: ${DEPLOY_HOST_ALIAS}"

# ---------- 3. Test the deploy key ----------
# GitHub returns a non-zero status even on success, and pipefail would turn
# "ssh | grep" into a failure, so capture the output once and match on it.
echo "Testing GitHub authentication with the deploy key..."
auth_output="$(
  ssh -i "${DEPLOY_KEY}" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=12 \
    -o StrictHostKeyChecking=accept-new \
    -T git@github.com 2>&1 || true
)"

if printf '%s\n' "${auth_output}" | grep -qi "successfully authenticated"; then
  echo "The deploy key was accepted by GitHub."
elif printf '%s\n' "${auth_output}" | grep -qi "permission denied"; then
  echo "GitHub rejected the deploy key: ${DEPLOY_KEY}" >&2
  echo "Add the matching public key under the repository's Settings > Deploy keys," >&2
  echo "with read-only access, then run this script again." >&2
  if [[ -f "${DEPLOY_KEY}.pub" ]]; then
    echo "----------------------------------------"
    cat "${DEPLOY_KEY}.pub"
    echo "----------------------------------------"
  else
    echo "No ${DEPLOY_KEY}.pub next to the private key; print it with:" >&2
    echo "  ssh-keygen -y -f ${DEPLOY_KEY}"
  fi
  exit 1
else
  # Usually a first-connection prompt that BatchMode refused.
  echo "GitHub connection test was inconclusive; continuing anyway." >&2
  printf '%s\n' "${auth_output}" | sed 's/^/  /' >&2
fi

# ---------- 4. Clone or update ----------
# Quoted so the key path survives spaces; the alias above already pins the key,
# this is a second guarantee when the config is not picked up.
GIT_SSH_COMMAND="ssh -i '${DEPLOY_KEY}' -o IdentitiesOnly=yes"
export GIT_SSH_COMMAND

if [[ -d "${TARGET_DIR}/.git" ]]; then
  echo "Updating the existing checkout: ${TARGET_DIR}"
  # A copy deployed earlier with another alias still points at that alias, which
  # would keep using a key this server no longer has; repoint it at the deploy key.
  if git -C "${TARGET_DIR}" remote get-url origin >/dev/null 2>&1; then
    git -C "${TARGET_DIR}" remote set-url origin "${REPO_URL}"
  else
    git -C "${TARGET_DIR}" remote add origin "${REPO_URL}"
  fi

  # --ff-only refuses to invent a merge commit on a read-only deployment; if the
  # server somehow diverged, git reports it instead of hiding it.
  git -C "${TARGET_DIR}" pull --ff-only origin "${BRANCH}"
  echo "Checkout updated to the latest ${BRANCH}."
else
  echo "Cloning ${GITHUB_REPO} into ${TARGET_DIR}..."
  git clone --branch "${BRANCH}" "${REPO_URL}" "${TARGET_DIR}"
  echo "Clone finished."
fi

# ---------- 5. Result ----------
echo
echo "============================================"
echo "Deployment finished."
echo "  Repository: ${GITHUB_REPO}"
echo "  Path:       ${TARGET_DIR}"
echo "  Branch:     $(git -C "${TARGET_DIR}" branch --show-current 2>/dev/null || echo 'N/A')"
echo "  Commit:     $(git -C "${TARGET_DIR}" log -1 --format='%h - %s (%cr)' 2>/dev/null || echo 'N/A')"
echo "============================================"
echo "This checkout is read-only for GitHub: the deploy key cannot push."
