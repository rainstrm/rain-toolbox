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
| `update_short_cuts.sh` | 更新 `rainstrm/short_cuts`；原有目录会先备份，不会直接删除。 |
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

配置 `github-rain` SSH 主机别名

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_github_ssh.sh)"
```

再切换到希望存放 `short_cuts` 的目录运行更新：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

也可以一次完成配置和更新：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_github_ssh.sh)" && bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/update_short_cuts.sh)"
```

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
