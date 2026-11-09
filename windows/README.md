# Windows 桌面入口

有交互桌面的 Windows 可以用这个界面扫码、搜索群、多选、启动和暂停。Windows Server Core、SSH 或后台服务场景用仓库根目录的命令行安装说明。

1. 按仓库根目录的 README 安装 Node.js 和锁定的依赖，准备仓库的 `.runtime/bin/wx.exe`。先完成依赖准备，再选择桌面模式初始化。
2. 在仓库根目录运行 `node bin/bot.mjs setup --desktop`，按提示在本机录入模型密钥。一个工作目录使用一种模式。如需同时保留命令行版与桌面版，使用不同的工作目录和空闲端口，并在不同时间运行微信连接。
3. 在一个终端运行 `node bin/bot.mjs gateway`，等待网关就绪，并保持这个终端运行。
4. 在同一目录另开一个 PowerShell，执行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -File .\windows\launcher-window.ps1 -Mode Start
   ```

5. 使用目标微信扫码确认，在群列表勾选需要接管的群，点击「在选中群启动机器人」。启动成功后可以关闭窗口，网关需要继续运行。只在选中的群回复，支持不带 `@` 的消息。
6. 要暂停回复并关闭桌面微信连接，在网关仍运行时执行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -File .\windows\launcher-window.ps1 -Mode Pause
   ```

已认证的桌面登录会话和群选择存放在 `.runtime/windows-launcher/`。桌面微信连接占用本机 `127.0.0.1:6276`，网关采用本仓库配置中的环回端口。首次扫码和真实群收发需要在目标 Windows 电脑确认。
