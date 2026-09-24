# rain-toolbox

这个仓库放置 `rainstrm` 常用的终端配置和维护脚本，用于初始化 Debian / Ubuntu
终端环境、配置 Vim、安装 GitHub SSH 公钥和更新快捷脚本。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `.vimrc` | 精简 Vim 配置：UTF-8、文件类型缩进、语法高亮、行号、鼠标、缩进和搜索增强。 |
| `setup_zsh_tools_debian.sh` | Debian / Ubuntu 安装 zsh、Oh My Zsh、Starship、eza、bat、fd、zoxide、Nerd Font 及两个 zsh 插件。会备份现有 `.zshrc` 和 Starship 配置。 |
| `setup_github_ssh.sh` | 使用本机已有的 `~/.ssh/id_rsa` 配置 `github-rain` GitHub SSH 主机别名。 |
| `install_rainstrm_github_key.sh` | 交互选择 `rainstrm` 的公开 GitHub SSH 公钥，并去重写入当前用户的 `~/.ssh/authorized_keys`。 |
| `update_short_cuts.sh` | 更新 `rainstrm/short_cuts`、修正脚本权限，并自动安装或更新 `requirements.txt` 中的 Python 模块。按 个人私钥 → 只读 Deploy Key → HTTPS 压缩包 的顺序自动选用一份可用凭证：有可用密钥就 `git` 原地更新（`logs/`、`.env` 等未入库文件保持原位，运行中脚本日志不断流），两份密钥都没有就把仓库压缩包下载下来直接覆盖文件；首次安装或非 git 目录会先备份再替换，并恢复 `.env` 等本地敏感文件；可选在更新后自动重启 Web 控制台。 |
| `deploy_github_repo.sh` | 交互选择并部署 GitHub 仓库；支持私有仓库、自定义仓库和安装目录，原目录会先备份。 |

## 远程运行 Shell 脚本

下面命令会从 GitHub 拉取脚本并交给 `bash` 执行。建议先确认脚本内容再运行。

### 安装 zsh / 常用终端工具

脚本面向 Debian / Ubuntu。安装完成后执行 `exec zsh -l`，或退出并重新连接 SSH。

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_zsh_tools_debian.sh)"
```

### 给当前服务器安装 rainstrm 的 GitHub 公钥

这个脚本需要在目标服务器的交互终端中运行。它会显示公钥编号，可输入 `1`、`1 2`
或 `1,2` 选择；直接回车或输入 `all` 安装全部。无交互终端时脚本会退出且不安装任何密钥。

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/install_rainstrm_github_key.sh)"
```

### 更新 short_cuts

切换到希望存放 `short_cuts` 的目录运行更新：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

脚本会自己挑一份可用的凭证，按顺序尝试，第一个能用的生效。密钥是用 `-i` 配合
`IdentitiesOnly` 显式指定的，因此**不再需要先跑 `setup_github_ssh.sh` 配置 `github-rain`
别名**（那个脚本仍然可以用来手工 `ssh -T git@github-rain` 或克隆别的仓库）：

| 顺序 | 凭证 | 更新方式 |
| --- | --- | --- |
| 1 | 个人私钥 `~/.ssh/id_rsa` | `git` 原地更新，可拉可推 |
| 2 | 只读 Deploy Key `~/.ssh/deploy_key_shortcuts` | `git` 原地更新（只读，推不了） |
| 3 | 两份都没有 | 下载仓库压缩包，直接把文件覆盖到本地 |

第 2 种是给**不能放个人私钥**的服务器准备的：Deploy Key 只对 `short_cuts` 这一个仓库生效，
而且只读，拿到它最多只能拉代码。在 GitHub 仓库 `Settings > Deploy keys` 里添加对应**公钥**
（不要勾选 "Allow write access"），私钥放到服务器 `~/.ssh/deploy_key_shortcuts` 并
`chmod 600` 即可；脚本发现密钥没被 GitHub 接受时会打印公钥内容并继续往下试。

第 3 种不需要任何密钥：脚本下载仓库压缩包（默认
`https://codeload.github.com/rainstrm/short_cuts/tar.gz/refs/heads/main`）后**原地覆盖**文件，
不移动目录本身，因此 `logs/`、`.env`、`web/data/auth.json` 这些未入库的运行状态不会被碰，
运行中的脚本日志也不会断流。两点注意：`short_cuts` 是私有仓库，匿名下载会 404，需要设置
`GITHUB_TOKEN`（或 `GH_TOKEN`）才有权限；另外这种方式判断不出"上游删了哪些文件"，只能靠本地
`.git` 里已检出的那个提交去比对，没有 `.git` 时上游删掉的文件会残留，恢复密钥后重跑一次
`git` 更新即可回到干净状态。

脚本会自动给 `expand/get_running_python.sh` 添加执行权限，并运行
`python3 -m pip install --upgrade --ignore-installed -r requirements.txt`。Debian 12+ 的 pip
如果支持 `--break-system-packages`，脚本会自动添加该参数。`--ignore-installed` 是必需的：
`lighter-sdk` 要求 `urllib3<2.1`，而 apt 装在 `/usr/lib/python3/dist-packages` 的 urllib3
没有 RECORD 文件，pip 卸载它会让整个脚本以 `uninstall-no-record-file` 中断。更新前会把原目录备份为
`short_cuts.bak.YYYYMMDD_HHMMSS`，并把旧目录里的 `.env`、`web/data/auth.json` 等
本地敏感文件恢复到新克隆，保留列表可用 `PRESERVE_FILES` 环境变量覆盖。
目标目录已经是 git 仓库时改为原地更新（`git fetch` + `git reset --hard`），
目录本身不会被替换，`logs/`、`.env` 等未跟踪文件原地保留，运行中的交易脚本
可以继续往原路径写日志；更新前的 HEAD 会保存到 `update-backup` 分支。
服务器上还可以保留一份持久的认证文件副本，并在更新后自动重启 Web 控制台：

```bash
AUTH_BACKUP_FILE=/root/auth.json RESTART_WEB_SERVICE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

`AUTH_BACKUP_FILE` 会把 `web/data/auth.json` 复制到指定路径（已存在则保留，不覆盖），
即使时间戳备份被删除也能恢复；`RESTART_WEB_SERVICE=1` 会在更新后重启
`web/server.py`（可用 `WEB_SERVER_SCRIPT`、`WEB_SERVER_PORT` 覆盖，端口默认 4188）。
只想更新代码、不安装 Python 模块时：

```bash
INSTALL_REQUIREMENTS=0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

也可以一次完成别名配置和更新（`github-rain` 别名只是方便手工 `ssh` 或克隆别的仓库，
更新本身不依赖它）：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_github_ssh.sh)" && bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

可覆盖的变量：

```bash
SHORT_CUTS_DIR="$HOME/short_cuts" \
SHORT_CUTS_BRANCH="main" \
SHORT_CUTS_REPO="git@github.com:rainstrm/short_cuts.git" \
GITHUB_SSH_KEY="$HOME/.ssh/id_rsa" \
DEPLOY_KEY="$HOME/.ssh/deploy_key_shortcuts" \
SHORT_CUTS_ARCHIVE="https://codeload.github.com/rainstrm/short_cuts/tar.gz/refs/heads/main" \
GITHUB_TOKEN="ghp_xxx" \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

`SHORT_CUTS_DIR` 默认是当前目录下的 `short_cuts`。`GITHUB_HOST_ALIAS` 也仍然可用：设成
`github-rain` 时脚本会用 `git@github-rain:...` 作为仓库地址，密钥依旧由脚本用 `-i` 指定。

### 交互部署任意 GitHub 仓库

先按上面的步骤运行 `setup_github_ssh.sh`，保证 Debian 服务器可以通过
`github-rain` 访问私有仓库。然后进入存放项目的父目录，直接在交互终端运行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/deploy_github_repo.sh)"
```

脚本菜单只包含 `Custom repository`，需要手动输入仓库名、`owner/name` 或完整 clone URL。
仅输入仓库名时，脚本会将其解析为 `rainstrm/仓库名`，但不会在工具仓库中保存该名称。
随后脚本会询问安装目录、可选分支或 tag，并在覆盖前显示最终配置、要求确认。

已有项目不会被删除，而是移动为同级的
`项目名.bak.YYYYMMDD_HHMMSS`；只有新仓库完整克隆成功后才会替换。部署结果只是仓库代码，
项目依赖安装、数据库迁移和服务重启仍应按项目自己的文档执行。

可以通过环境变量修改 GitHub 所有者、SSH 主机别名或安装根目录：

```bash
GITHUB_OWNER="rainstrm" \
GITHUB_HOST_ALIAS="github-rain" \
DEPLOY_ROOT="/srv" \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/deploy_github_repo.sh)"
```

## 服务器一键使用

在新的 Debian / Ubuntu 服务器上运行下面命令，会下载 `.vimrc` 到 `~/.vimrc`，然后安装
zsh、Oh My Zsh、Starship、eza、bat、fd、zoxide 和 Nerd Font：

```bash
bash -c 'set -euo pipefail; BASE="https://raw.githubusercontent.com/rainstrm/rain-toolbox/main"; curl -fsSL "$BASE/.vimrc" -o "$HOME/.vimrc"; bash -c "$(curl -fsSL "$BASE/setup_zsh_tools_debian.sh")"'
```

只安装 Vim 配置：

```bash
curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/.vimrc -o ~/.vimrc
```

## 本机 GitHub SSH 配置

仓库克隆到本机后，或直接从 GitHub 运行：

```bash
bash setup_github_ssh.sh
```

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_github_ssh.sh)"
```

配置完成后可验证 SSH 身份：

```bash
ssh -T git@github-rain
```

然后可通过 SSH 克隆仓库：

```bash
git clone git@github-rain:rainstrm/rain-toolbox.git
```
