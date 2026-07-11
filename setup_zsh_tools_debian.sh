#!/usr/bin/env bash
set -euo pipefail

# Install a practical zsh environment on Debian/Ubuntu.
# Optional: NERD_FONT_NAME=FiraCode bash setup_zsh_tools_debian.sh

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

TARGET_USER="$(id -un)"
TARGET_HOME="${HOME}"

ZSH_DIR="${TARGET_HOME}/.oh-my-zsh"
ZSH_CUSTOM="${ZSH_CUSTOM:-${ZSH_DIR}/custom}"
ZSHRC="${TARGET_HOME}/.zshrc"
STARSHIP_CONFIG="${TARGET_HOME}/.config/starship.toml"
NERD_FONT_NAME="${NERD_FONT_NAME:-JetBrainsMono}"
NERD_FONT_DIR="${TARGET_HOME}/.local/share/fonts/NerdFonts/${NERD_FONT_NAME}"
MANAGED_BEGIN="# >>> rain-toolbox managed block >>>"
MANAGED_END="# <<< rain-toolbox managed block <<<"

echo "Installing tools for ${TARGET_USER} (${TARGET_HOME})"
${SUDO} apt-get update
${SUDO} apt-get install -y zsh git curl ca-certificates wget bat fd-find fontconfig xz-utils

if ! command -v eza >/dev/null 2>&1; then
  if apt-cache show eza >/dev/null 2>&1; then
    ${SUDO} apt-get install -y eza
  else
    echo "eza is unavailable from this distribution; continuing without it."
  fi
fi

if [[ ! -f "${ZSH_DIR}/oh-my-zsh.sh" ]]; then
  installer="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "${installer}"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes ZSH="${ZSH_DIR}" sh "${installer}"
  rm -f "${installer}"
fi

mkdir -p "${ZSH_CUSTOM}/plugins"
install_plugin() {
  local url="$1"
  local directory="$2"
  if [[ -d "${directory}/.git" ]]; then
    git -C "${directory}" pull --ff-only
  elif [[ ! -e "${directory}" ]]; then
    git clone --depth=1 "${url}" "${directory}"
  fi
}

install_plugin https://github.com/zsh-users/zsh-autosuggestions.git \
  "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
install_plugin https://github.com/zsh-users/zsh-syntax-highlighting.git \
  "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"

mkdir -p "${TARGET_HOME}/.local/bin"
export PATH="${TARGET_HOME}/.local/bin:${PATH}"

if ! command -v zoxide >/dev/null 2>&1; then
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi

if ! command -v starship >/dev/null 2>&1; then
  curl -sS https://starship.rs/install.sh | sh -s -- -y -b "${TARGET_HOME}/.local/bin"
fi

mkdir -p "$(dirname "${STARSHIP_CONFIG}")"
if [[ -f "${STARSHIP_CONFIG}" ]]; then
  cp "${STARSHIP_CONFIG}" "${STARSHIP_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
fi
starship preset catppuccin-powerline -o "${STARSHIP_CONFIG}" --force

if [[ ! -d "${NERD_FONT_DIR}" ]]; then
  font_tmp="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${NERD_FONT_NAME}.tar.xz" \
    -o "${font_tmp}/${NERD_FONT_NAME}.tar.xz"
  mkdir -p "${NERD_FONT_DIR}"
  tar -xJf "${font_tmp}/${NERD_FONT_NAME}.tar.xz" -C "${NERD_FONT_DIR}"
  rm -rf "${font_tmp}"
  fc-cache -f "${TARGET_HOME}/.local/share/fonts" || true
fi

touch "${ZSHRC}"
cp "${ZSHRC}" "${ZSHRC}.bak.$(date +%Y%m%d_%H%M%S)"

if grep -qF "${MANAGED_BEGIN}" "${ZSHRC}" && grep -qF "${MANAGED_END}" "${ZSHRC}"; then
  awk -v begin="${MANAGED_BEGIN}" -v end="${MANAGED_END}" '
    $0 == begin { managed=1; next }
    $0 == end { managed=0; next }
    managed != 1 { print }
  ' "${ZSHRC}" > "${ZSHRC}.tmp"
  mv "${ZSHRC}.tmp" "${ZSHRC}"
fi

cat >> "${ZSHRC}" <<'EOF'

# >>> rain-toolbox managed block >>>
export ZSH="$HOME/.oh-my-zsh"
export PATH="$HOME/.local/bin:$PATH"
ZSH_THEME=""
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source "$ZSH/oh-my-zsh.sh"

if command -v eza >/dev/null 2>&1; then
  alias ls='eza --icons=auto --group-directories-first'
  alias ll='eza --icons=auto --group-directories-first --long --header --git'
  alias la='eza --icons=auto --group-directories-first --long --header --all --git'
  alias tree='eza --tree --level=2 --icons=auto --group-directories-first'
fi

if command -v batcat >/dev/null 2>&1; then
  alias bat='batcat'
  alias cat='batcat'
elif command -v bat >/dev/null 2>&1; then
  alias cat='bat'
fi

command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
# <<< rain-toolbox managed block <<<
EOF

ZSH_BIN="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "${TARGET_USER}" | cut -d: -f7 || true)"
if [[ "${CURRENT_SHELL}" != "${ZSH_BIN}" ]]; then
  ${SUDO} chsh -s "${ZSH_BIN}" "${TARGET_USER}"
fi

echo "Done. Select '${NERD_FONT_NAME} Nerd Font' in your terminal, then run: exec zsh -l"
