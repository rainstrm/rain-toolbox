# rain-toolbox

`rainstrm` 的个人终端配置与维护脚本仓库。项目参考了
[`rmbbiji/rmbbiji-toolbox`](https://github.com/rmbbiji/rmbbiji-toolbox) 的用途，
但账号、SSH 配置和脚本都已独立整理

## 内容

| 文件 | 用途 |
| --- | --- |
| `.vimrc` | 无插件的轻量 Vim 配置 |
| `setup_zsh_tools_debian.sh` | 在 Debian/Ubuntu 安装 zsh、Oh My Zsh、Starship、常用插件与终端工具 |
| `setup_github_ssh.sh` | 用现有私钥配置独立的 `github-rain` SSH 主机别名 |
| `install_rainstrm_github_key.sh` | 交互选择并安装 `rainstrm` 在 GitHub 公开的一个或多个 SSH 公钥 |
| `update_short_cuts.sh` | 更新 `rainstrm/short_cuts`，并保留旧目录备份 |

## 本机首次配置

### 1. 检查 SSH 私钥

默认使用 `~/.ssh/id_rsa`。私钥权限应为 `600`：

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_rsa
```

私钥只能保存在本机，不能提交到 Git。仓库的 `.gitignore` 已忽略常见密钥文件，
但提交前仍应执行 `git status` 检查。

### 2. 配置 GitHub 主机别名

```bash
bash setup_github_ssh.sh
ssh -T git@github-rain
```

成功时 GitHub 会显示：

```text
Hi rainstrm! You've successfully authenticated, but GitHub does not provide shell access.
```

如果私钥不在默认位置：

```bash
GITHUB_SSH_KEY=/path/to/private_key bash setup_github_ssh.sh
```

### 3. 配置 Git 作者信息

将邮箱替换成你的 GitHub 邮箱，或 GitHub 提供的 `noreply` 邮箱：

```bash
git config --global user.name "rainstrm"
git config --global user.email "你的 GitHub 邮箱"
```

只想对当前仓库生效时，把 `--global` 换成 `--local`。

### 4. 克隆与推送

```bash
git clone git@github-rain:rainstrm/rain-toolbox.git
cd rain-toolbox
git add .
git commit -m "Initial toolbox setup"
git push -u origin main
```

日常更新：

```bash
git pull --ff-only
# 修改文件后
git add .
git commit -m "Describe the change"
git push
```

## 安装终端环境

脚本适用于 Debian/Ubuntu，会修改 `~/.zshrc` 和 `~/.config/starship.toml`，
并在修改前创建带时间戳的备份。

仓库已公开，因此可以通过 `raw.githubusercontent.com` 直接获取配置文件和脚本。
直接执行远程脚本前，仍建议先打开对应链接检查内容。

从已克隆仓库运行：

```bash
bash setup_zsh_tools_debian.sh
exec zsh -l
```

从 GitHub 直接运行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/setup_zsh_tools_debian.sh)"
```

安装 Vim 配置：

```bash
curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/.vimrc -o ~/.vimrc
```

## 给服务器添加登录公钥

在目标服务器上以需要授权的用户运行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rainstrm/rain-toolbox/main/install_rainstrm_github_key.sh)"
```

脚本只下载 `https://github.com/rainstrm.keys` 中的公开密钥，并显示每把密钥的
编号、类型、SHA256 指纹和备注。存在多把公钥时，可以输入 `1`、`1 2` 或 `1,2`
选择要安装的密钥；在交互终端中直接回车或输入 `all` 会安装全部。已经存在于
`~/.ssh/authorized_keys` 的密钥不会重复添加。这和上传私钥完全不同：服务器只需要公钥。

脚本强制要求交互终端。通过管道、定时任务、CI 或关闭标准输入运行时会直接退出，
不会下载或安装任何公钥。上面的 `bash -c "$(curl ...)"` 会保留终端输入；不要改成
`curl URL | bash`，后者没有可供脚本读取的交互式标准输入。

## 更新 short_cuts

先执行一次 `setup_github_ssh.sh`，再运行：

```bash
bash update_short_cuts.sh
```

默认目标是当前目录下的 `short_cuts`。可覆盖仓库或安装位置：

```bash
SHORT_CUTS_REPO=git@github-rain:rainstrm/short_cuts.git \
SHORT_CUTS_DIR="$HOME/py/short_cuts" \
bash update_short_cuts.sh
```

## 常见问题

`Permission denied (publickey)`：确认公钥已经添加到 GitHub 的
**Settings > SSH and GPG keys**，再运行 `ssh -vT git@github-rain` 查看实际使用的密钥。

`Host key verification failed`：先运行 `ssh -T git@github.com`，核对并接受 GitHub
主机指纹。官方指纹见 [GitHub 文档](https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)。

推送提示没有上游分支：运行 `git push -u origin main`，以后可直接 `git push`。

## License

[MIT](LICENSE)
