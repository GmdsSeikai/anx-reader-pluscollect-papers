# Windows 论文采集验收

自动化测试、原生探针和人工操作分别记录证据。探针使用真实 Windows SQLite FFI、WebView2 和 PDF 阅读器；它不显示主窗口，也不能证明窗口交互或外部 WebDAV 账号可用。

## 自动化检查

在项目目录使用与 `.github/flutter-version` 一致的 Flutter SDK：

```powershell
flutter test --no-pub --reporter expanded
$env:PAPER_LIVE_SOURCES = '1'
flutter test --no-pub test/service/papers/live_sources_test.dart --reporter expanded
Remove-Item Env:PAPER_LIVE_SOURCES
flutter build windows --no-pub --release --target=lib/main.dart
git diff --check
```

实时来源测试默认跳过，显式启用后访问 arXiv 和 Semantic Scholar。429 或网络失败应记录为本次真实接入未通过；已有夹具测试不代替真实接入结果。不要固定断言外部引用次数。

## 原生隔离探针

临时数据必须放在 `D:/Develop/Misc Workspace/archive/` 内。首次目录必须为空；探针写入归属标记，恢复运行检查该标记。在初始化偏好设置前，`installNativePaperTestPaths` 同时替换应用路径提供器和 `SharedPreferencesWindows.pathProvider`：Windows 偏好插件使用独立的路径提供器，仅替换 `PathProviderPlatform.instance` 不足以隔离偏好。偏好、缓存、两份数据库、PDF、封面和 WebView2 数据均归该目录所有。运行前后核对正式偏好与书库文件哈希。

```powershell
flutter build windows --no-pub --release --target=test/native_windows/paper_collection_probe.dart
$probeRoot = 'D:/Develop/Misc Workspace/archive/paper-collection-native-run'
New-Item -ItemType Directory -Path $probeRoot
$env:PAPER_NATIVE_TEST_ROOT = $probeRoot
$env:PAPER_NATIVE_TEST_MODE = 'seed'
$probeExe = (Resolve-Path 'build/windows/x64/runner/Release/anx_reader.exe').Path
$seedProcess = Start-Process -FilePath $probeExe -WorkingDirectory (Split-Path $probeExe) -WindowStyle Hidden -PassThru
$seedProcess.WaitForExit()
$seedProcess.Refresh()
$seedProcess.ExitCode
Get-Content "$probeRoot/seed-result.json"
$env:PAPER_NATIVE_TEST_MODE = 'resume'
$resumeProcess = Start-Process -FilePath $probeExe -WorkingDirectory (Split-Path $probeExe) -WindowStyle Hidden -PassThru
$resumeProcess.WaitForExit()
$resumeProcess.Refresh()
$resumeProcess.ExitCode
Get-Content "$probeRoot/resume-result.json"
```

两次必须退出 0，结果中的 `passed` 必须为 `true`。内部设有四分钟超时；外部启动器也应设置有限等待，只结束自己启动的 PID。输出日志放在探针目录外，否则首次空目录校验会拒绝启动。

- `seed`：真实发现并下载 `1706.03762`，经生产导入入口与 WebView2 保存 PDF，取得真实阅读位置，保存书签，重建封面，同时运行普通重复导入和封面重建，拒绝错误 PDF；留下主库已提交、论文关联未完成的状态。
- `resume`：在新进程恢复关联、书签和阅读位置；由本机 HTTP 夹具向生产 WebDAV 客户端提供替换数据库，将原书移动到另一 ID 并占用旧 ID，验证按 MD5 打开正确书籍；再运行生产存储迁移，核对两份数据库、书签和 PDF 阅读。

迁移只清理探针自建的旧存储目录。执行前检查归属、绝对路径和链接，保存 `migration-preview.json`；目标位于同一探针根目录内。HTTP 服务为测试夹具，只证明客户端传输与数据库替换，不证明外部账号认证、完整同步页面或所有 WebDAV 操作。

每个新验收运行使用新目录，保留旧结果和日志。完整重复恢复测试应从新 `seed` 开始，避免对已经迁移的目录再次运行迁移。

所有测试目标共享原生宿主 `anx_reader.exe`，宿主哈希无法区分 Dart 入口。记录构建命令、`data/app.so` 哈希与完整包清单。探针运行后必须重新构建 `--target=lib/main.dart`，恢复正式发布目录。

## 人工隔离应用

单独构建 `test/native_windows/paper_collection_manual.dart`，复制**整个** Release 目录到本次归档的 `manual-app`。该入口重定向路径后启动生产应用，不注入候选、模型响应或服务客户端。使用一个空的归档数据目录设置 `PAPER_MANUAL_TEST_ROOT`，由操作者启动应用；不要直接启动正式入口进行隔离验收，正式入口不会读取此变量。

2026-10-10 本机续验的启动器：

```powershell
& 'D:/Develop/Misc Workspace/archive/paper-collection-native-validation/start-isolated-reader.ps1'
```

启动器打开可见的验收应用，本次修正隔离后的数据为同一归档下的 `manual-data-isolation-08`。启动器校验 `data/app.so` 哈希，防止误启动正式入口。先正常关闭该实例，再重开；不要并行启动同一验收数据目录。

按以下步骤记录实际结果、时间及失败点，保存在本次任务归档：

| 步骤 | 操作与预期 | 对应验收 |
| --- | --- | --- |
| 创建任务 | 进入论文页，新建关键词/研究主题任务；检查五个模板需手动保存；作者为独立发现分支；默认最近 30 天与 12 个月可改 | P02、P14 |
| 发现与排序 | 没有 AI 密钥也能运行；任务页分别显示最新与历史窗口的进度和失败范围；最新相关与近期高被引独立，未知引用可见且不同于 0 | P03、P07、P14 |
| 候选操作 | 查看原始标题、摘要、作者、日期、发现依据和引用更新时间；五任务筛选、分页、低相关性/待分析筛选、缩窄窗口均可操作 | P01、P07、P14 |
| 批量导入 | 明确勾选多篇后下载；一篇失败不阻断其他篇；失败项可重试；成功项进入书架并打开 PDF | P10、P11、P14 |
| 阅读与旧入口 | 保存书签/标注及阅读位置；普通文件导入与封面重建可完成，重复导入保留现有书籍内容与进度 | P11、P12 |
| 进程生命周期 | 采集中切换页面和最小化继续运行；正常关闭无剩余采集进程；在隔离实例采集中结束该实例，重开显示中断并可继续 | P05 |
| 外部同步 | 使用专用测试 WebDAV 账号或明确隔离的远端目录；同步后论文仍打开正确书籍并保留标注；采集库不进入整库同步 | P12、P13 |
| 存储入口 | 从设置将隔离存储迁移到另一个空归档目录；任务、候选、额度、原书、封面和标注保持，重开仍可阅读 | P13 |
| 分析配置 | 如需验收真实模型，配置测试服务后核对缓存复用、额度、摘要依据；采集与阅读聊天并行，分别取消互不影响 | P06、P08、P09 |

原生窗口操作通常由操作者完成；本次用户已明确授权接管鼠标键盘，自动化只能操作经 PID 和可执行文件路径核验的隔离实例。真实鼠标键盘输入还必须核验前台窗口；窗口消息与 PrintWindow 截图须核验目标窗口归属。浏览器仍使用无头 Playwright。分页、低相关性和批量失败若采用夹具，必须标明夹具 ID 与数量，并与真实 arXiv 发现、下载证据分开。尚未运行的步骤标记为待验，不能将发布构建成功写成全功能验收。
