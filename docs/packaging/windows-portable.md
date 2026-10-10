# Windows 便携版

适用于 Windows 10/11 x64。运行前需要安装 Microsoft Edge WebView2 Runtime；压缩包包含安读所需的应用资源、插件及 Visual C++ 运行库。

解压到独立目录，保留全部文件，双击 `anx_reader.exe` 启动。桌面快捷方式的目标为该文件，“起始位置”为解压目录。程序使用当前用户的安读设置和书库，不会把书库写进程序目录。

`package-manifest.json` 记录压缩包内各文件的 SHA256，可用于核对解压后文件是否完整。

论文采集功能位于“论文”页，需要联网访问 arXiv。可配置关键词、研究主题和独立作者分支，再手动运行或在应用打开期间定时采集。勾选候选后下载 PDF；AI 和引用补充服务均可选。

更新时先关闭应用，将新版本解压到另一个目录并修改快捷方式目标。需要回退时关闭新版本，再使用保留的旧程序目录；不要删除或替换书库存储目录。

维护者使用 `scripts/build_windows.ps1` 构建并打包。`-SkipBuild` 可复用已验证的正式 Release 构建；`-StagingDirectory` 必须为空，`-OutputDirectory` 内不能已有 `app.zip`。默认输出为 `build/windows/unsigned/app.zip`。此脚本创建便携 ZIP；exe 安装器仍由既有 Inno Setup 流程生成。
