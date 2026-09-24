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
| `update_short_cuts.sh` | 检查 GitHub SSH、更新 `rainstrm/short_cuts`、修正脚本权限，并自动安装或更新 `requirements.txt` 中的 Python 模块。已有 git 目录会原地更新（`logs/`、`.env` 等未入库文件保持原位，运行中脚本日志不断流）；首次安装或非 git 目录会先备份再替换，并恢复 `.env` 等本地敏感文件；可选在更新后自动重启 Web 控制台。 |
| `deploy_github_repo.sh` | 交互选择并部署 GitHub 仓库；支持私有仓库、自定义仓库和安装目录，原目录会先备份。 |
| `update_short_cuts_deploy_key.sh` | 面向**不适合放 `rainstrm` 个人 GitHub 私钥**的服务器：只用单仓库只读 Deploy Key 部署或更新 `short_cuts`。自动写入专属 SSH 主机别名、按需补 `known_hosts`、单独校验 Deploy Key，再克隆或用 `git pull --ff-only` 更新。 |

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

配置 `github-rain` SSH 主机别名

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_github_ssh.sh)"
```

再切换到希望存放 `short_cuts` 的目录运行更新：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

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

也可以一次完成配置和更新：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_github_ssh.sh)" && bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

### 用只读 Deploy Key 更新 short_cuts（服务器没有个人 GitHub 私钥时）

有些服务器不适合放 `rainstrm` 的个人 GitHub 私钥，只给一份**该仓库专用的只读 Deploy Key**。
这类服务器用这个脚本，它不依赖 `github-rain` 别名，也完全不会碰到个人私钥：

1. 把 Deploy Key 私钥放到服务器 `~/.ssh/deploy_key_shortcuts`，并设为 `chmod 600`；
2. 在 GitHub 仓库 `Settings > Deploy keys` 里添加对应的**公钥**，权限保持只读
   （不要勾选 "Allow write access"）；
3. 运行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts_deploy_key.sh)"
```

脚本会写入 `Host github.com-deploy-shortcuts` 配置块（用标记块原地重写，重复运行不会叠加）、
按需补 `known_hosts`、用 `IdentitiesOnly` 单独测试 Deploy Key 是否被接受（被拒绝时打印公钥，
方便直接粘到 GitHub），然后克隆或更新 `~/short_cuts`。目录已经是 git 仓库时执行
`git pull --ff-only`：不会产生合并提交，也无法 push；如果旧部署的 remote 指向别的别名，
会自动改写成 Deploy Key 的地址。

可覆盖的变量：

```bash
GITHUB_REPO="rainstrm/short_cuts" \
DEPLOY_KEY="$HOME/.ssh/deploy_key_shortcuts" \
TARGET_DIR="$HOME/short_cuts" \
BRANCH="main" \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts_deploy_key.sh)"
```

这类服务器只拿到代码，不会安装 Python 依赖、也不会重启 Web 服务；需要这些步骤请按
`short_cuts` 项目自己的文档处理。`update_short_cuts.sh` 依赖 `github-rain` 别名（即个人私钥），
在只给 Deploy Key 的服务器上跑不了，这也是本脚本存在的原因。

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
