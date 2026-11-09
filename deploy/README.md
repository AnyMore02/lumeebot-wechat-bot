# 服务器托管

先按根目录 README 用目标系统用户安装依赖、设置 Key、扫码和选群。手动运行通过后再配置开机启动。两个服务使用同一个工作目录和系统用户，网关与微信端口维持环回访问。

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
