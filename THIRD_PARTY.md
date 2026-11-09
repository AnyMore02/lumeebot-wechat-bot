# 第三方组件

| 组件 | 锁定版本 | 取得方式 |
| --- | --- | --- |
| OpenClaw | 2026.10.7 | npm，完整传递依赖和完整性记录见 `package-lock.json`。 |
| agent-wechat OpenClaw 插件 | 1.2.0 | npm 包 `@agent-wechat/agent-wechat`，安装后应用仓库内的版本化补丁。 |
| wx 原生程序 | 1.2.0 | agent-wechat GitHub Releases，按平台选择文件并核对 SHA-256。 |

依赖各自的许可、通知和源码来源随上游发布。Node.js 在目标机独立安装。补丁的原始及结果文件 SHA-256 写在对应文件中。微信插件补丁重现本机已部署的版本，包括账号重连状态检查、Windows 文件系统兼容、实时群过滤及收发诊断。OpenClaw 补丁让已入库的微信消息按其原有会话和去重键继续处理，避免图片识别失败后的重复写入冲突。

[OpenClaw npm 版本](https://www.npmjs.com/package/openclaw/v/2026.10.7) · [agent-wechat 发行版](https://github.com/thisnick/agent-wechat/releases/tag/v1.2.0)
