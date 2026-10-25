# 青茄阅读 · 当前状态交接（AGENT-HANDOVER-NEXT）

> 更新时间：2026-10-25 04:30 (UTC+8)（第 2~7 组交付后重写；环境/工具链部分不变，见下）
> 仓库：E:\项目\青茄阅读\repo\fqapp-src（Windows 侧路径；WSL 内为 /mnt/e/项目/青茄阅读/repo/fqapp-src）
> 远端：https://github.com/fangyuzhang/qingdu-reader-app（已改名，旧地址 qingqie-reader-app 自动重定向）
> 分支：master（HEAD de66506，已与远端同步）；本地另有已合并的 refactor/slim-optimize 分支可删
> 版本：1.0.131+136　包名：com.fqapp.fqapp

本文是唯一有效的当前状态说明。AGENT-HANDOVER.md 是早期归档。逐批变更细节看 QINGQIE-CHANGES.md（已记到第 55 批 + 瘦身重构）；本次优化验收报告在 OPTIMIZATION-REPORT.md，护栏在 OPTIMIZATION-GUARDRAILS.md。

---

## 0. 30 秒速览

| 项 | 值 |
| --- | --- |
| 测试基线 | flutter analyze 0 问题；flutter test 1542 通过 / 10 跳过 / 0 失败 |
| 真机 | Redmi K20 Pro，serial b2f8e975（adb 在 D:\APP\DevTools\Android\Sdk\platform-tools\adb.exe） |
| 已装 APK | 最新 release（含 v41–v55 + 瘦身重构），构建产物完好（.so 已修复） |
| 远端同步 | master 已推送并校验 SHA 一致 |
| 当前代码形态 | 玻璃主题已整体移除；首页为 PageView 融合导航；笔记划线并入类型筛选；**新增 PDF 固定版式阅读 + 手写墨迹批注（第 2~7 组，v1.0.132+137，提交 37cd8c8..本批）** |

---

## 0.5 七组交付速览（2026-10-25，详见 QINGQIE-CHANGES.md 五十六~六十二）

- **新增能力**：① PDF 导入（SAF 选择器 + 文件管理器「打开方式」ACTION_VIEW 双通道，64MB）与固定版式阅读（pdfrx 2.2.x，进度 positionVersion:3 按页存取）；② 手写墨迹批注：PDF 整页锚定（字符区间+指纹，PDFium 逐字符坐标）与阅读器分页模式固定布局批注（layoutVersion 版本化，退出后锚点区间以虚线投影回流式视图）；③ 批注诊断页（调试）。
- **新文件**：lib/pages/{pdf_reader_page, stylus_probe_page, annotation_diagnostics_page}.dart、lib/services/{ink_annotation_store, anchor_projector, pdf_intent_import}.dart、lib/models/ink_annotation.dart、lib/widgets/reader/annotation/{ink_canvas, ink_controller, ink_strokes_painter, ink_toolbar}.dart、android/.../PdfViewIntentPlugin.kt。
- **修改要点**：imported_book_store（pdf 分支/source.pdf 落盘/64MB）、LocalBookPickerPlugin.kt（MIME+上限）、MainActivity/Manifest（VIEW intent）、reader_page（批注模式挂载，全部为附加式插入，分页/滚动/进度逻辑未动）、reader_controls（批注/墨迹入口）、library_store.init（补 InkAnnotationStore.hiveReady=true）。
- **本机 pub 缓存补丁（3 处，flutter pub cache repair 会还原）**：pdfium_flutter CMake 下载走 ghproxy.net 镜像；同文件 Windows 宿主用合并拷贝替代 .lib/latest 符号链接（并修并行 ABI 竞态导致 libpdfium.so 未入包）；pdfrx_engine 0.3.9 pdf_file_cache.dart 两处 cache!. 空安全 AOT 编译错。详见 PDF-RENDER-SELECTION.md。
- **验证遗留（设备掉线前未完成，优先级从高到低）**：
  1. 墨迹存储在极端 force-stop 下偶发丢失（怀疑 Hive 半帧+checksum 误判 wipe；已加 save 后 flush + dispose 落盘两道防线，复验未再出现；encrypted_hive 属禁改区）。复验法：批注→完成→`adb shell am force-stop`→重开看墨迹；异常时设置→服务→批注诊断（调试）看「存储：entries=」与 AppLog ink-store 告警。
  2. MatePad 11 + M-Pencil 3：pressure 范围/tilt 可用性/书写 ≥50fps（探测页在设置→服务→手写笔探测）。
  3. SAF 手选导入 PDF 的用户手测（MIUI 拦截系统选择器的自动化点击，代码路径与已验证的 intent 导入相同）。
- **调试开关**：`--dart-define=fqapp.debugTools=true` 让调试页出现在 release 包（默认 release 不可见，签名同正式包可覆盖安装）。


---

## 1. 绝对环境事实（新 agent 必读，全是踩过的坑）

### 1.1 路径与验证

1. flutter analyze / flutter test / flutter build 绝不能在中文路径下执行——仓库在 E:\项目\青茄阅读\...，Dart analysis server 遇中文路径直接崩溃（FormatException）。
   标准流程：改 E:\项目\青茄阅读\repo\fqapp-src → robocopy 同步到 E:\fqapp-build2（ASCII 构建副本）→ 在副本里跑验证：

   cd /e/ && robocopy "E:\项目\青茄阅读\repo\fqapp-src\lib" "E:\fqapp-build2\lib" //MIR //NFL //NDL //NJH //NP
   robocopy "E:\项目\青茄阅读\repo\fqapp-src\test" "E:\fqapp-build2\test" //MIR //NFL //NDL //NJH //NP
   cp "E:\项目\青茄阅读\repo\fqapp-src\pubspec.yaml" /e/fqapp-build2/
   cd /e/fqapp-build2 && flutter pub get && flutter analyze && flutter test

2. E:\fqapp-build（无 2）是废弃目录，勿用：曾因构建中被锁/强删导致 gradle 中间产物损坏，打出的 APK 里 libfqapi_core.so 被截断 145 字节，装机后报「本地服务启动失败」（v55 事故）。构建目录损坏的修法：换全新目录完整 robocopy + flutter pub get + 干净构建；验收标准是 APK 内 .so 长度 6,444,168（与源文件差 8 字节为 gradle 规范化，正常）。E:\fqapp-build 现仍被进程锁着删不净，重启后可 cmd //c "rmdir /S /Q E:\fqapp-build" 清掉。
3. robocopy 多源 cp 陷阱：cp a b /目标/ 会把文件散拷到目标根目录制造幽灵文件（analyze 报不带 lib/ 前缀的诡异错误）。每次 cp 必须逐文件写全目标路径；见幽灵错误先 ls /e/fqapp-build2/*.dart 查散件。

### 1.2 工具链（Windows 侧，本机全部就绪）

| 工具 | 位置 / 版本 |
| --- | --- |
| Flutter | D:\APP\DevTools\Flutter（3.47.7 stable，与锁定版本一致；Git Bash 里直接 flutter 可用） |
| JDK 17 | D:\APP\DevTools\JDK（JAVA_HOME 已设） |
| Android SDK | D:\APP\DevTools\Android\Sdk（NDK 28.2.13676358、build-tools 36 均在） |
| Gradle | 项目 gradlew 9.1.0，缓存在 ~/.gradle（9.1.0 已缓存，无需下载） |
| Python | 系统 Python + PIL/numpy（截图像素分析用） |

### 1.3 构建与签名

首次准备（副本已配好，重建副本时需要）：
  cd /e/fqapp-build2 && rm -f android/local.properties
  sed -i 's|storeFile=.*|storeFile=C:/Users/zjh30/WorkBuddy/2026-10-19-08-17-51/release-signing/qingqie-release.jks|' android/keystore.properties
  flutter pub get

构建 + 装机：
  flutter build apk --release --target-platform android-arm64
  ADB=/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe
  $ADB -s b2f8e975 install -r build/app/outputs/flutter-apk/app-release.apk
  $ADB -s b2f8e975 shell am start -n com.fqapp.fqapp/.MainActivity

- keystore 密码在 E:\项目\青茄阅读\signing\SIGNING-SECRETS.txt；android/keystore.properties 是 git 忽略的本地文件。
- ~/.gradle/gradle.properties 里的 VPN 代理（127.0.0.1:51981）已被注释——仓库走阿里云镜像可直连。若用户开了 VPN 导致构建失败，按文件内注释改回端口。
- APK 归档惯例：cp <apk> /d/APP/agent/apk/fqapp-vNN.apk。

### 1.4 Git 与推送（重点：Windows 侧没有凭据）

- Windows 侧 git push 不可用：无 gh CLI、无 token、直连 github.com 被断。
- 推送必须走 WSL（原机凭据都在里面）：

  wsl -d Ubuntu-24.04 -- bash -c "export PATH=/home/fy/.local/bin:\$PATH; cd /mnt/e/项目/青茄阅读/repo/fqapp-src && git push origin master"

  （WSL 内 gh 已登录 fangyuzhang，ghproxy 镜像规则在 WSL 的 ~/.gitconfig。仓库本地 credential helper 用了裸 gh，必须先 export PATH，否则 Invalid username or token。）
- 推送后校验：git ls-remote origin master 与 git rev-parse HEAD 一致。
- git 身份已配：青茄阅读 <dev@qingqie.local>（仓库本地 config）。
- 提交规范（AGENTS.md）：area: 结果，正文写 为什么/怎么验/影响面。

### 1.5 真机验证手法（视觉取证链）

- 截图：$ADB exec-out screencap -p > x.png，用 python PIL 做像素分析（定位按钮/对比前后帧/验证动画消失：两帧卡片区 diff=0.0 即无动画）。
- 坐标陷阱：内部 Read 工具看截图是缩放的，显示坐标 × 1.187 ≈ 真实坐标；视觉模型报的坐标不可靠，一律用像素扫描定位（按图标颜色聚类找中心）。
- dumpsys gfxinfo 对 Flutter 自绘 surface 统计恒 0 帧（MIUI Android 11 限制），帧率取证不可行。
- input motionevent DOWN/MOVE/UP 可注入长按拖拽（DOWN 后静置 ≥0.9s 再 MOVE）；input draganddrop 长按保持不稳定。注入中途截图可能打断手势流。
- 证据截图归档：E:\项目\青茄阅读\releases\glass-theme-shots\。

### 1.6 脚本/工具坑（改代码时）

- python heredoc 陷阱：python - <<'PYEOF' 里的中文长段/反引号会被 bash 吞导致锚点失配或命令替换。改文件一律用 Write 写 .py 临时文件再 python file.py，跑完删除。
- Edit 工具锚点必须字节级精确（注意 en-dash、中文标点）；大范围删除区间前先用括号配平扫描（剥离字符串/注释后数括号）确认边界，删完必须立即 analyze——本会话两次事故（reader_page 误删 build/_showCache/_menuEdge 共 5 个方法；多余闭括号）都是删区间过宽，靠 analyze/format 定位修复。
- git checkout -- <file> 恢复单文件时注意：基线之前的 HEAD 是旧代码，会连带丢掉该文件上的近期批次改动（本会话曾因此重做 v49 修复）。恢复前先 git diff <file> | grep "^-" 确认要丢什么。

---

## 2. 当前代码形态（v41–v55 + 瘦身重构后的最终状态）

### 2.1 主题系统

- AppTheme.createTheme(brightness, {einkMode})（lib/services/app_theme.dart）+ 顶层 themeModeNotifier / einkModeNotifier + main.dart 双层 ValueListenableBuilder；220ms 日夜插值（eink 瞬时）。
- 玻璃主题已整体删除（v54，用户反馈「太丑」）：lib/feature/ 已删、全部使用点还原实色。用户偏好 key glass_mode/glass_strength 可能还留在设备 SharedPreferences 里，无人读取，无害。
- HomePalette（widgets/home/home_design.dart）仍是取色中枢：accent=0xFF2FA98C，muted=#5E6B64，accentText 浅色 #176B58。

### 2.2 首页（lib/pages/home_page.dart，~945 行）

- PageView 融合导航（v51）：第 0 页推荐视图，第 1–7 页各分类全部书城（CategoryBrowseView 内嵌于 lib/pages/category_browse_page.dart，KeepAlive 保活）。顶部分类条常驻，_revealChip（GlobalKey + Scrollable.ensureVisible）随翻页同步高亮/滚动。
- 磁贴（CuratedBookTile）套书架式白卡（v47）；分类兜底渐变已收敛为 CuratedCategory.defaultGradient（瘦身 2B）。
- 板块横滑 _MagneticSnapPhysics（磁力吸附，整本对齐，甩动惯性投影 0.22s）；滑到末尾过冲 36dp 进分类全部页（v48，从 72 下调）。
- 每板块 10 本（v48）：_recommendedBooksOf limit:10；书单 assets/config/curated_books.json 每分类 10 本（补过 28 本）；recommendationBatchOf 在 limit≥总数时按批次轮转日序（换一批仍有效）。
- 精选卡（v46 最终版）：原尺寸布局（封面 88px 左、文字右），白底 palette.surface + 0.6 描边；无「今日荐读/年龄」标签，无轮换副文案。用户明确否决过整幅大封面版本。
- 听书页/听书 chip 已删（v50）；书单 audio 书走磁贴直达音频详情。
- 下拉刷新（CategoryBrowseView._loadBatch）：advance 时不读缓存不清屏，网络批次一次性替换（v52 修复「刷两次」）。

### 2.3 笔记（lib/pages/notes_page.dart，~2100 行）

- 视图只有 时间线/按书查看（划线不再是独立视图，v52）；类型行 = 全部/批注/书摘/划线（NoteTypeFilter.marks）。
- 选「划线」后「全部类型」行切换为线型 chips（实线/波浪线/虚线/荧光笔，key notes-mark-style-*）；时间线渲染 _buildMarkTimeline（日期轴+线型色点+_MarkRow）。
- 卡片（v44）：无时间戳（保留章节名）、无分类 chip（_MetaChip 已删）、想法（thought）有与原文同款 8% 色底。
- 拖拽（v41 系列）：磁力虚影插进角标排序落位（ghostId 机制）；_leavingBadges 松手瞬间隐藏源角标防残影（写库失败回滚+SnackBar）；拖回自己 = 半透明角标无绿环（v41.4，用户明确要求只删绿环保留半透明）。

### 2.4 阅读器（lib/pages/reader_page.dart，4598 行——瘦身后）

- ChapterDirectorySheet 已拆到 lib/widgets/reader/chapter_directory_sheet.dart（public，瘦身 2C）。
- 底部工具栏平底（无顶圆角，v47）；正文区域永不加任何视觉特效。
- 返回详情页抖动已修（v49）：PopScope.onPopInvokedWithResult didPop 分支立即恢复 edgeToEdge（_appliedSystemUiMode 幂等）；dispose 兜底保留。
- _stableInsets 冻结安全区机制（工具栏显隐正文不跳）；墨水屏 eink 主题在 _createEinkTheme。

### 2.5 书架（lib/pages/library_page.dart）

- 卡片无入场动画（v53 移除 HomeEntrance，_entered 已删；首页的错峰动画保留）。
- 封面 Hero 飞行动画已删（v45，bookshelf_card + detail_hero 两侧）。
- 长按=进编辑模式（多选），编辑态内拖拽排序。

### 2.6 禁改区（AGENTS.md / 护栏文件为准）

rust/、native/、android 构建协议代码、lib/widgets/reader/reader_theme.dart（正文背景）、正文绘制/分页/滚动/书签/进度路径、lib/widgets/shelf/ 卡片本体。技术锁：FRB 2.13.0、仅 arm64-v8a、16KiB 对齐。完整清单见 OPTIMIZATION-GUARDRAILS.md（硬边界部分长期有效）。README.md 的九条界面交互约定改 UI 前必读。

### 2.7 瘦身重构结果（已合并）

三波（2A/2B/2C）：空 catch 8 处补 AppLog.w（app_log.dart 自身 1 处保留防递归）；flutter_riverpod 移除；渐变常量收敛；ChapterDirectorySheet 拆分。评估后主动跳过的：24 处 showModalBottomSheet 不收敛（异构）、30 处异步骨架不统一、4 个大文件不拆（理由在 OPTIMIZATION-REPORT.md §3–4）。提交 b1e51c4 / 08f8bc1 / da62b2a，merge e7ee4e0。

---

## 3. 开发调试设施

- flutter_skill（调试绑定）：main.dart 里 if (!kReleaseMode) FlutterSkillBinding.ensureInitialized(autoEnableIndicators: false)——autoEnableIndicators 必须 false（500ms 定时器会让 widget 测试报 Pending timers）。依赖 flutter_skill: ^0.9.37（pub 上没有 0.2.26 这种版本，外部文档若写 0.2.x 是错的）。
- flutter-skill MCP：注册在 C:\Users\zjh30\.zcode\cli\config.json（stdio，cmd /c C:\Users\zjh30\.flutter-skill\start-mcp.cmd）。wrapper 先删单实例锁 ~/.flutter_skill.lock 再启动（该 server 单实例锁与 ZCode 会话隔离冲突，stale 锁会 Connection closed）。npm 全局包 flutter-skill 0.9.36 驱动 0.9.37 原生二进制（二进制是手动从 v0.9.37 release 下载放到 ~/.flutter-skill/bin/ 的，v0.9.36 release 不存在）。
- agent skills：25 个 Flutter/Dart 官方 
