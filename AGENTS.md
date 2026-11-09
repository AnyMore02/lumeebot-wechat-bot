# 安装交接

先读 [README](README.md)。检查目标系统、CPU 架构和 Node.js 版本，使用仓库根目录的统一命令行流程。只有带交互桌面的 Windows 才考虑 `windows/` 的可选界面。

遵守 `package-lock.json` 和 wx 校验值。运行 `npm ci` 及 `node scripts/prepare-runtime.mjs` 后再生成配置。保持运行状态位于当前工作目录的 `.runtime/`，避免接入或改动现有全局 OpenClaw 服务。API Key 由运行者在目标机录入，微信扫码也由账号持有人操作。

验收时先看 `node bin/bot.mjs status`，然后请使用者在授权的测试群发送一条新文字。多群验收需确认各群独立收到回复。只将运行过的验证报告为通过，并把实际故障与未验证项分开说明。

`workspace/AGENTS.md` 和相邻文件属于机器人运行时的 Lumeebot 人设与产品资料。
