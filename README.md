# Lumeebot 微信群机器人

让 Lumeebot 小羊在指定微信群中回答问题。支持多选群，普通消息无需 @，每个群各自保留会话。产品知识、人设、微信插件修复和 OpenClaw 的图片回复冲突修复都在这个仓库的安装流程中。

Linux 服务器可使用 [Docker Compose 部署](deploy/README.md#linux-docker-compose)。下文是 Linux 和 Windows 的原生安装流程，带桌面的 Windows 也可使用图形启动器。

## 安装前确认

- Windows x64 / ARM64，或 Linux x64 / ARM64。Linux 需要 glibc 2.36 或更新版本，例如 Debian 12 或 Ubuntu 24.04。wx 1.2.0 的 Linux 发行包使用 GNU ABI。 [原生程序平台说明](https://github.com/thisnick/agent-wechat/blob/v1.2.0/PLATFORM-ACCEPTANCE.md)
- 安装 Git 和 Node.js 24.22.1 以上的 24.x，或 Node.js 26.12.1 及更新版本，确保 `node` 和 `npm` 在当前终端可用。安装需要访问 npm 和 GitHub Releases。 [Node.js 下载](https://nodejs.org/en/download)
- 准备使用者自己的 DeepSeek API Key，以及已经加入目标群的微信账号。首次登录由微信账号持有人在手机上扫码并确认。 [DeepSeek API 文档](https://api-docs.deepseek.com/zh-cn/api_samples/chat_curl/) · [微信插件说明](https://github.com/thisnick/agent-wechat)

## 1. 下载并准备运行环境

用将来实际运行机器人的系统用户执行。

```sh
git clone https://github.com/AnyMore02/lumeebot-wechat-bot.git
cd lumeebot-wechat-bot
npm ci
node scripts/prepare-runtime.mjs
```

在 Windows PowerShell 中如果 `npm` 被脚本执行策略拦截，使用 `npm.cmd ci`。运行准备脚本时，程序会按系统和 CPU 架构下载并校验 wx 1.2.0，再将两个补丁应用于仓库内锁定的依赖。已正确应用的补丁可以重复校验。每次重新运行 `npm ci` 后，重新运行准备脚本再启动。

## 2. 配置 API Key

```sh
node bin/bot.mjs setup
```

在目标电脑的终端中按提示输入 API Key，输入不会回显。设置会生成本机网关令牌，把密钥和状态保存在仅当前运行用户可访问的 `.runtime/`，配置通过 SecretRef 读取。首次设置后微信通道处于暂停状态。现用预设为 DeepSeek 的 `deepseek-flash` 文字方案。 [OpenClaw 密钥配置](https://docs.openclaw.ai/gateway/secrets/secretref-contract)

默认只监听本机 `127.0.0.1:19789`（网关）和 `127.0.0.1:6275`（微信）。如与现有进程冲突，在**首次**设置前指定两个不同的空闲端口。

```sh
LUMEEBOT_GATEWAY_PORT=19790 LUMEEBOT_WX_PORT=6277 node bin/bot.mjs setup
```

```powershell
$env:LUMEEBOT_GATEWAY_PORT='19790'
$env:LUMEEBOT_WX_PORT='6277'
node bin/bot.mjs setup
```

已保存的端口会在重启后继续使用。若选择 [Windows 图形启动器](windows/README.md)，首次设置改用 `node bin/bot.mjs setup --desktop`，再按对应文档操作。两种模式使用不同的工作目录。

## 3. 登录微信并选群

下面是 Linux 和 Windows Server 的命令行流程。先启动微信服务并创建本机账号槽位。

```sh
node bin/bot.mjs wx daemon start
node bin/bot.mjs wx --json accounts create --alias lumeebot
```

记下命令返回的 `id`，下文的 `ACCOUNT_ID` 用这个值替换。已经建过账号槽位时，用 `node bin/bot.mjs wx --json accounts list` 查找，不必再创建。

```sh
node bin/bot.mjs wx --account ACCOUNT_ID auth login --strategy qr --force-qr --timeout 300 --qr-output .runtime/wechat-login.png
node bin/bot.mjs wx --account ACCOUNT_ID groups list
```

扫码命令会等待手机确认。远程服务器上可用 SSH/SCP 把生成的二维码图片取到自己的电脑查看，二维码有时效。群目录未同步完成时稍后查询，按已同步群的真实 ID 选择。可用 `node bin/bot.mjs wx --account ACCOUNT_ID chats find 群名 --kind group` 按名称查找。

```sh
node bin/bot.mjs groups ACCOUNT_ID GROUP_A@chatroom GROUP_B@chatroom
node bin/bot.mjs gateway
```

以上群 ID 为占位符。可选一个或多个群，每次提交完整的目标群列表。网关在前台运行。另开终端在仓库根目录执行 `node bin/bot.mjs status` 查看就绪状态和群数量。请先在测试群发一条新文字验证，再在两个选中群分别发新消息，核对各自收到回复。

## 日常运行

| 操作 | 命令 |
| --- | --- |
| 查看网关和群配置 | `node bin/bot.mjs status` |
| 暂停群回复 | `node bin/bot.mjs pause` |
| 用已登录账号和已选群恢复 | `node bin/bot.mjs resume` |
| 查看本机网关日志 | `node bin/bot.mjs openclaw logs --follow` |
| 核对本机配置 | `node bin/bot.mjs openclaw config validate` |
| 停止微信服务 | `node bin/bot.mjs wx daemon stop` |

机器重启后，先启动微信服务，再启动网关。微信登录状态仍有效时可以沿用原账号。切换账号前先暂停，登录新账号后重新提交该账号的目标群。运行中的服务可由目标服务器的服务管理器托管，示例见 [服务器托管说明](deploy/README.md)。

## 交付范围与验收

- `workspace/` 包含 Lumeebot 的产品资料、对外身份和回答规则。
- `bin/` 提供服务端命令，`windows/` 提供可选的 Windows 桌面入口。
- `package-lock.json` 锁定可下载依赖，`patches/` 和 `scripts/prepare-runtime.mjs` 负责恢复已验证的程序修复。上游来源见 [第三方组件](THIRD_PARTY.md)。
- 程序默认使用单把 DeepSeek Key 跑文字回复。图片回复修复允许图片处理失败后继续回复文字。需要让机器人实际理解图片时，安装者须配置并实测目标图片模型，使用目标群的引用图片做验收。
- 原电脑的密钥、微信授权、群配置、聊天数据和日志留在原电脑。目标机的运行数据由 `setup`、扫码和选群步骤各自生成。

Windows 本机已完成依赖安装与补丁校验。Linux 和 Windows 的自动验收覆盖安装、空白配置及隔离测试。真实微信扫码和双群收发由部署者在目标机完成。
