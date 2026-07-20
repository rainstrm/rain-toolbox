#!/usr/bin/env bash
set -euo pipefail

# Interactively replace a local project with a freshly cloned repository.
# Configure the menu with DEPLOY_PROJECTS, for example:
#   DEPLOY_PROJECTS="backpack_rwa short_cuts another_owner/another_repo"

GITHUB_OWNER="${GITHUB_OWNER:-rainstrm}"
GITHUB_HOST_ALIAS="${GITHUB_HOST_ALIAS:-github-rain}"
DEPLOY_ROOT="${DEPLOY_ROOT:-${PWD}}"
DEPLOY_PROJECTS="${DEPLOY_PROJECTS:-backpack_rwa short_cuts}"

if [[ ! -t 0 ]]; then
  echo "An interactive terminal is required." >&2
  echo "Run this script directly and select a project at the prompt." >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  echo "git is required" >&2
  exit 1
}

declare -a projects=()
read -r -a projects <<< "${DEPLOY_PROJECTS}"

if (( ${#projects[@]} == 0 )); then
  echo "DEPLOY_PROJECTS does not contain any projects." >&2
  exit 1
fi

repo_url=""
repo_name=""
repo_label=""

resolve_repository() {
  local repository="$1"
  local slug=""
  local path_without_query=""

  if [[ "${repository}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    slug="${GITHUB_OWNER}/${repository}"
    repo_name="${repository}"
    repo_url="git@${GITHUB_HOST_ALIAS}:${slug}.git"
    repo_label="${slug}"
  elif [[ "${repository}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]]; then
    slug="${repository%.git}"
    repo_name="${slug##*/}"
    repo_url="git@${GITHUB_HOST_ALIAS}:${slug}.git"
    repo_label="${slug}"
  else
    path_without_query="${repository%%\?*}"
    path_without_query="${path_without_query%/}"
    repo_name="${path_without_query##*/}"
    repo_name="${repo_name%.git}"

    if [[ ! "${repo_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "Unable to determine a project name from: ${repository}" >&2
      return 1
    fi

    repo_url="${repository}"
    repo_label="${repository}"
  fi
}

echo "Projects available for deployment:"
for index in "${!projects[@]}"; do
  project="${projects[index]}"
  if [[ "${project}" == */* ]]; then
    display_name="${project%.git}"
  else
    display_name="${GITHUB_OWNER}/${project}"
  fi
  printf '  [%d] %s\n' "$((index + 1))" "${display_name}"
done
custom_index=$((${#projects[@]} + 1))
printf '  [%d] Custom repository\n' "${custom_index}"

selection=""
printf 'Select a project [1]: '
read -r selection
selection="${selection:-1}"

if [[ ! "${selection}" =~ ^[0-9]+$ ]] \
  || (( 10#${selection} < 1 || 10#${selection} > custom_index )); then
  echo "Invalid selection: ${selection}" >&2
  exit 1
fi

if (( 10#${selection} == custom_index )); then
  custom_repository=""
  printf 'Repository (name, owner/name, or clone URL): '
  read -r custom_repository
  if [[ -z "${custom_repository}" ]]; then
    echo "A repository is required." >&2
    exit 1
  fi
  resolve_repository "${custom_repository}"
else
  resolve_repository "${projects[$((10#${selection} - 1))]}"
fi

default_target="${DEPLOY_ROOT%/}/${repo_name}"
target_input=""
printf 'Install directory [%s]: ' "${default_target}"
read -r target_input
target_input="${target_input:-${default_target}}"

case "${target_input}" in
  "~")
    target_dir="${HOME}"
    ;;
  "~/"*)
    target_dir="${HOME}/${target_input#\~/}"
    ;;
  /*)
    target_dir="${target_input}"
    ;;
  *)
    target_dir="${PWD}/${target_input}"
    ;;
esac

target_dir="${target_dir%/}"
target_name="$(basename "${target_dir}")"
parent_dir="$(dirname "${target_dir}")"

if [[ -z "${target_dir}" || "${target_dir}" == "/" \
  || "${target_name}" == "." || "${target_name}" == ".." ]]; then
  echo "Refusing unsafe install directory: ${target_dir:-<empty>}" >&2
  exit 1
fi

branch=""
printf 'Branch or tag [repository default]: '
read -r branch

echo
echo "Repository: ${repo_label}"
echo "Clone URL:  ${repo_url}"
echo "Target:     ${target_dir}"
if [[ -n "${branch}" ]]; then
  echo "Revision:   ${branch}"
fi
if [[ -e "${target_dir}" || -L "${target_dir}" ]]; then
  echo "Existing target: will be moved to a timestamped backup."
else
  echo "Existing target: none; this will be a new installation."
fi

confirmation=""
printf 'Continue? [y/N]: '
read -r confirmation
case "${confirmation}" in
  y|Y|yes|YES|Yes)
    ;;
  *)
    echo "Cancelled."
    exit 0
    ;;
esac

mkdir -p "${parent_dir}"
tmp_dir="$(mktemp -d "${parent_dir}/.${target_name}.deploy.XXXXXX")"
backup_dir=""

cleanup() {
  rm -rf "${tmp_dir}"
  if [[ -n "${backup_dir}" \
    && ( -e "${backup_dir}" || -L "${backup_dir}" ) \
    && ! -e "${target_dir}" && ! -L "${target_dir}" ]]; then
    echo "Restoring the previous project..." >&2
    mv "${backup_dir}" "${target_dir}"
  fi
}
trap cleanup EXIT

clone_args=(--recurse-submodules)
if [[ -n "${branch}" ]]; then
  clone_args+=(--branch "${branch}")
fi

echo "Cloning ${repo_label}..."
git clone "${clone_args[@]}" "${repo_url}" "${tmp_dir}"

if [[ -e "${target_dir}" || -L "${target_dir}" ]]; then
  backup_dir="${target_dir}.bak.$(date +%Y%m%d_%H%M%S)"
  while [[ -e "${backup_dir}" || -L "${backup_dir}" ]]; do
    backup_dir="${backup_dir}.1"
  done
  echo "Backing up existing target to ${backup_dir}"
  mv "${target_dir}" "${backup_dir}"
fi

mv "${tmp_dir}" "${target_dir}"
trap - EXIT

deployed_commit="$(git -C "${target_dir}" rev-parse --short HEAD)"
echo "Deployed: ${target_dir} (${deployed_commit})"
if [[ -n "${backup_dir}" ]]; then
  echo "Previous version: ${backup_dir}"
fi
