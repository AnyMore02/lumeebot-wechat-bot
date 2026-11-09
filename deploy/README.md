# 服务器部署

## 交付内容

| 项目 | 交付 |
| --- | --- |
| 系统代码和构建脚本 | [GitHub 源码](https://github.com/AnyMore02/lumeebot-wechat-bot)、[依赖锁文件](../package-lock.json)、[运行时准备脚本](../scripts/prepare-runtime.mjs)。镜像构建时安装锁定依赖，按平台下载并校验 wx，再应用版本化补丁。 |
| Docker 脚本 | [Dockerfile](../Dockerfile) 和 [compose.yaml](../compose.yaml)，服务名为 `bot`，用 `docker compose build` 构建。 |
| 运行端口 | 容器内 `127.0.0.1:19789/TCP` 是 OpenClaw 网关，`127.0.0.1:6275/TCP` 是 wx 服务。Compose 不映射宿主机端口，无应用入站端口需要开放。 |
| 数据目录 | 宿主机示例 `/srv/lumeebot-wechat-bot/.runtime`，容器内 `/app/.runtime`。 |
| 域名 | 本次通过 SSH 管理和扫码，无需配置 DNS、证书或反向代理。未来若另行部署 Web 管理入口，可考虑 `lmchat.haohantonghui.com`。 |

构建时需要能访问 Docker Hub、Debian 软件源、npm registry 和 GitHub Releases（包括下载跳转地址）。运行时需要正常 DNS 解析，能出站访问 DeepSeek API（`api.deepseek.com:443`）及微信服务端（TCP 80 和 443）。 [wx 上游协议实现](https://github.com/thisnick/agent-wechat/blob/v1.2.0/packages/native-client-rust/crates/wechat-protocol/src/mmtls.rs#L228-L247)

## Linux Docker Compose

以下以 Linux x86_64 服务器为例。先确认 `docker info` 和 `docker compose version` 可用，由管理员准备可写的部署目录并授权运行 Docker。使用者自行准备 DeepSeek API Key，以及已经加入目标群的微信账号。

### 构建并配置

在管理员分配的目录下执行以下命令。这里以 `/srv` 为部署目录的上级为例。

```sh
cd /srv
git clone https://github.com/AnyMore02/lumeebot-wechat-bot.git
cd lumeebot-wechat-bot
sudo install -d -m 0700 -o 1000 -g 1000 .runtime
docker compose config
docker compose build
docker compose run --rm --no-deps bot setup
docker compose up -d --wait --wait-timeout 210
docker compose ps
```

按 `setup` 提示输入自己的 DeepSeek API Key，输入不会回显。容器以非 root 用户运行，UID/GID 为 `1000:1000`，运行目录必须属于该用户。端口在首次设置时写入持久化配置，容器内用默认值即可。

### 扫码并选群

首次部署时创建微信账号槽位，记下输出的 `id`。

```sh
docker compose exec bot node bin/bot.mjs wx --json accounts create --alias lumeebot
```

已有账号槽位时，执行 `docker compose exec bot node bin/bot.mjs wx --json accounts list` 查询现有 ID。把下面的 `ACCOUNT_ID` 换成真实值。登录命令会等待手机确认。

```sh
docker compose exec bot node bin/bot.mjs wx --account ACCOUNT_ID auth login --strategy qr --force-qr --timeout 300 --qr-output /app/.runtime/wechat-login.png
```

二维码生成后，在第二个 SSH 终端进入仓库目录，将二维码复制到 SSH 用户的私有临时目录。

```sh
qr_dir=$(mktemp -d)
docker compose cp bot:/app/.runtime/wechat-login.png "$qr_dir/wechat-login.png"
printf '%s\n' "$qr_dir/wechat-login.png"
```

在自己的电脑上通过 SCP 下载该路径的图片并及时扫码。登录命令完成后，删除二维码及其临时副本，再查看已同步的群。

```sh
docker compose exec bot rm -f /app/.runtime/wechat-login.png
docker compose exec bot node bin/bot.mjs wx --account ACCOUNT_ID groups list
```

如果群目录还在同步，稍后再查。也可在同一个账号下用 `chats find '群名' --kind group` 搜索。把下面的占位符换成真实群 ID，可填一个或多个。每次执行 `groups` 时提交完整的目标群列表。

```sh
docker compose exec bot node bin/bot.mjs groups ACCOUNT_ID GROUP_A@chatroom GROUP_B@chatroom
docker compose restart bot
docker compose ps
docker compose exec bot node bin/bot.mjs status
```

等待容器状态显示 `healthy`，确认 `gatewayReady` 和 `channelEnabled` 都是 `true`，并核对 `selectedGroupCount`。请让另一位群成员在授权测试群发送一条新文字，无需 @；多群部署时，分别在两个选中群发送新消息并确认各自收到回复。容器健康状态反映本地服务就绪，真实回复需通过上述群消息验收。

### 运维与数据

| 操作 | 命令 |
| --- | --- |
| 查看进程和近期日志 | `docker compose ps`、`docker compose logs --tail=100 bot` |
| 查看群配置摘要 | `docker compose exec bot node bin/bot.mjs status` |
| 暂停群回复 | `docker compose exec bot node bin/bot.mjs pause` |
| 恢复已选群回复 | `docker compose exec bot node bin/bot.mjs resume` |
| 退出或重新启动 | `docker compose stop bot` 或 `docker compose up -d` |
| 更新 | 备份数据后更新源码，执行 `docker compose up -d --build --wait --wait-timeout 210`。 |

`.runtime/` 内的 `keys/` 存放 DeepSeek Key 和网关令牌，`openclaw/` 存放配置和会话，`wx/` 存放微信账号状态，`consumer/` 存放接收进度。运行时还会生成 `ports.json`、`mode` 和日志。镜像自带 wx 可执行文件与 `workspace/` 产品资料。容器重建会继续使用挂载的数据。备份前停止容器，备份整个 `.runtime/`，恢复时保留文件权限和归属，并使用同一个容器内路径。运行目录和备份含密钥及微信数据，请限制访问。

## 原生进程托管

先按 [主安装说明](../README.md) 用目标系统用户安装依赖、设置 Key、扫码和选群。手动运行通过后再配置开机启动。两个服务使用同一个工作目录和系统用户，网关与微信端口维持环回访问。

## Linux systemd 用户服务

下面以 `/srv/lumeebot-wechat-bot` 和 `/usr/bin/node` 为例。安装者需要替换为目标机上的实际绝对路径。可先用 `command -v node` 核对 Node 路径。两个文件都放在实际运行用户的 `~/.config/systemd/user/`。

`lumeebot-wx.service`

```ini
[Unit]
Description=Lumeebot WeChat local daemon

[Service]
Type=simple
WorkingDirectory=/srv/lumeebot-wechat-bot
ExecStart=/usr/bin/node /srv/lumeebot-wechat-bot/bin/bot.mjs wx serve
Restart=on-failure
RestartSec=5
KillMode=control-group
```

`lumeebot-gateway.service`

```ini
[Unit]
Description=Lumeebot isolated OpenClaw gateway
After=lumeebot-wx.service
Requires=lumeebot-wx.service

[Service]
Type=simple
WorkingDirectory=/srv/lumeebot-wechat-bot
ExecStart=/usr/bin/node /srv/lumeebot-wechat-bot/bin/bot.mjs gateway
Restart=on-failure
RestartSec=5
KillMode=control-group

[Install]
WantedBy=default.target
```

在切到 systemd 之前结束前台网关，再在项目目录执行 `node bin/bot.mjs wx daemon stop`，释放旧实例占用的端口。加载用户服务。

```sh
systemctl --user daemon-reload
systemctl --user enable --now lumeebot-gateway.service
systemctl --user status lumeebot-gateway.service lumeebot-wx.service
journalctl --user -u lumeebot-gateway.service -u lumeebot-wx.service -f
```

用户退出登录后是否继续运行由服务器的 systemd 用户会话设置决定。需要无登录开机运行时，请让管理员为实际运行用户启用 linger，或用独立服务用户部署系统级单元。

## Windows Server

可以用两个独立的 Windows 计划任务，分别运行 `node.exe bin/bot.mjs wx serve` 和 `node.exe bin/bot.mjs gateway`。使用实际 Node.exe 的绝对路径，把任务的「起始于」设为仓库根目录，两项任务都用扫码、配置时的同一个 Windows 用户运行。网关任务在微信任务之后启动。任务名可用 `Lumeebot-WeChat` 和 `Lumeebot-Gateway`，以便和现有 OpenClaw 任务区分。

切换前先退出手动运行的网关，再用 `node bin/bot.mjs wx daemon stop` 停止旧微信进程。安装者应在目标机验证任务运行账号、端口、重启后微信状态和测试群回复。
