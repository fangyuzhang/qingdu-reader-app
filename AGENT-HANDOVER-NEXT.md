# 青茄阅读 · 当前状态交接（AGENT-HANDOVER-NEXT）

> 更新时间：2026-10-25 18:10 (UTC+8)（手写墨迹批注 + PDF 阅读 + 标签磁吸拖拽全部交付后重写；本文是唯一有效的当前状态说明，AGENT-HANDOVER.md 是早期归档）
> 仓库：E:\项目\青茄阅读\repo\fqapp-src（Windows 侧路径；WSL 内为 /mnt/e/项目/青茄阅读/repo/fqapp-src）
> 远端：https://github.com/fangyuzhang/qingdu-reader-app（旧地址 qingqie-reader-app 自动重定向）
> 分支：master，HEAD **<提交后为准>**，已与远端校验一致
> 版本：1.0.132+137　包名：com.fqapp.fqapp
> 逐批变更细节看 QINGQIE-CHANGES.md（已记到第 69 批）；扩展点施工图在 EXTENSION-SURVEY-REPORT.md；PDF 选型在 PDF-RENDER-SELECTION.md

---

## 0. 30 秒速览

| 项 | 值 |
| --- | --- |
| 测试基线 | flutter analyze 0 问题；flutter test 1547 通过 / 10 跳过 / 0 失败 |
| 真机 | Redmi K20 Pro，serial b2f8e975（adb 在 D:\APP\DevTools\Android\Sdk\platform-tools\adb.exe）；**MatePad 11 + M-Pencil 3 未到位**（压感/帧率实测遗留） |
| 已装 APK | 验证构建（--dart-define=fqapp.debugTools=true）；正式归档 D:\APP\agent\apk\fqapp-v67.apk（1.0.132+137 无调试页） |
| 远端同步 | master 已推送并校验 SHA 一致（67bb55f） |
| 当前代码形态 | v41–v55 全部优化 + **新增 PDF 固定版式阅读、手写墨迹批注（PDF + 阅读器双端）、标签磁吸拖拽垃圾桶删除、笔记「手写」类型筛选**（第 2~7 组 + 63~69 批） |

---

## 0.4 最新修复（2026-10-25 晚，第 67~69 批，全部已装真机验证）

1. **冷启动灰条根因终修（69 批，本次）**：根因是 Android 10+ 对「透明状态栏」默认开启对比度保护 scrim（引擎 PlatformPlugin.java 512-514 行证实；框架 SystemUiOverlayStyle 预设的 systemStatusBarContrastEnforced 为 null → 从不下发 false）。三层关闭：MainActivity 原生 isStatusBarContrastEnforced=false（早于首帧）+ main.dart 系统栏消息提前到 runApp 之前 + 全部透明状态栏样式补 contrast=false。真机冷启动连拍验证：状态栏条带 0% 灰 / 97% 奶油底。**教训：透明状态栏必须同时关 contrast，否则必出灰条；阅读器没灰条是因为它用不透明正文底色。**
2. **垃圾桶交互四连（67 批）**：按住的 chip 必须拖动全程保持 Draggable 存活（隐藏槽位会杀掉 Draggable → onDragEnd 丢失 → 状态卡死）；垃圾桶常驻 AppBar（compact 形态）；armed 唯一来源 = DragTarget candidate；磁吸吸收几何 = 水平≤88 且垂直≤48。
3. **MIUI 截屏陈旧帧陷阱**：连续快速 screencap 会返回字节级相同帧，验证必须 md5 查重 + 加间隔。

## 0.5 本轮交付速览（2026-10-25，第 2~7 组 + 63~66 批）

### 新增能力

1. **PDF 固定版式阅读**（第 4 组）：SAF 选择器 + 文件管理器「打开方式」ACTION_VIEW 双通道导入（64MB 上限）；pdfrx 2.2.x 渲染原版式；进度按页存取（positionVersion:3）；`PdfReaderPage.pageText()` 暴露逐字符坐标表供批注锚定。
2. **手写墨迹批注**（第 3/5/6 组）：InkAnnotation 模型（归一化坐标 + 字符区间锚点 + 前后 32 字符指纹 + 页面快照 + layoutVersion）；加密 Hive 盒 reader_ink_annotations_v1；PDF 整页锚定 + 阅读器分页模式固定布局批注双端；退出后锚点区间以虚线投影回流式视图。
3. **标签磁吸拖拽**（63~66 批）：笔记页与批注编辑器的标签可长按拖入顶部垃圾桶删除；多选磁吸组整组跟手；垃圾桶周围径向暗化；「拖出即删」已取消、改为弹回原位，删除只走垃圾桶。
4. **调试设施**：设置→服务→「手写笔探测」「批注诊断」（--dart-define=fqapp.debugTools=true 让调试页出现在 release 包，签名同正式包可覆盖安装）。

### 新文件

- lib/pages/{pdf_reader_page, stylus_probe_page, annotation_diagnostics_page}.dart
- lib/services/{ink_annotation_store, anchor_projector, pdf_intent_import}.dart
- lib/models/ink_annotation.dart
- lib/widgets/reader/annotation/{ink_canvas, ink_controller, ink_strokes_painter, ink_toolbar}.dart
- lib/widgets/notes/tag_trash.dart
- android/.../PdfViewIntentPlugin.kt
- 文档：EXTENSION-SURVEY-REPORT.md（七组任务施工图）、PDF-RENDER-SELECTION.md（PDF 选型与本机构建适配）

### 修改要点

- imported_book_store（pdf 分支/source.pdf 落盘/64MB 上限）、LocalBookPickerPlugin.kt（MIME+上限）、MainActivity/Manifest（VIEW intent）、reader_page（批注模式挂载，全部为附加式插入，分页/滚动/进度逻辑未动）、reader_controls（手写/墨迹入口）、notes_page（手写筛选 + 标签拖拽垃圾桶 + 磁吸组）、library_store.init（补 InkAnnotationStore.hiveReady=true）、about_page（版本同步）。

### 验证遗留（按优先级）

1. **MatePad 11 + M-Pencil 3 实测**（设备未到位）：pressure 范围/tilt 可用性/书写 ≥50fps；用设置→服务→手写笔探测页；注意工具栏窄屏折两行，「手指绘制」开关在第二行，仅调试构建可见。
2. **SAF 手选导入 PDF 人工手测**：MIUI DocumentsUI 拦截注入式文件项点击（自动化只能点到搜索/菜单/抽屉），代码与已验证的 ACTION_VIEW 通道同路，人手点一下即可。
3. **调色板行磁吸组拖删真机手指复验**：MIUI 水平滚动容器会抢 adb 注入拖拽的 Arena（语义已由 widget 测试锁定），建议真机手指过一遍。

### 已排除的假象（勿重复排查）

- 「墨迹 force-stop 丢失」：真相是自动化假象（adb 注入事件 kind=unknown 被画布按规格拒绝，从未画出一笔）+ 工具栏溢出导致「完成/手指绘制」在屏外。均已修复；真机闭环复验通过（画两笔→完成退出→force-stop→重启 entries=1 且墨迹原位渲染）。
- MIUI screencap 旧帧陷阱：拖拽/动画进行中或刚结束时，screencap 可能返回陈旧合成帧（字节级相同即中招）。关键状态用语义树（uiautomator dump）断言，不要信单张截图。

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
3. robocopy 多源 cp 陷阱：`cp a b /目标/` 会把文件散拷到目标根目录制造幽灵文件（本会话曾发生 notes_page.dart 幽灵拷进 lib/services/，analyze 报不带 lib/ 前缀的诡异错误）。每次 cp 必须逐文件写全目标路径；见幽灵错误先 `ls /e/fqapp-build2/lib/**/*.dart` 对照 git ls-files 查散件。

### 1.2 工具链（Windows 侧，本机全部就绪）

| 工具 | 位置 / 版本 |
| --- | --- |
| Flutter | D:\APP\DevTools\Flutter（3.47.7 stable，与锁定版本一致；Git Bash 里直接 flutter 可用） |
| JDK 17 | D:\APP\DevTools\JDK（JAVA_HOME 已设） |
| Android SDK | D:\APP\DevTools\Android\Sdk（NDK 28.2.13676358、build-tools 36、cmake 3.22.1 均在） |
| Gradle | 项目 gradlew 9.1.0，缓存在 ~/.gradle（9.1.0 已缓存，无需下载） |
| Python | 系统 Python + PIL/numpy（截图像素分析用） |

### 1.3 构建与签名

验证构建（含调试页）：
  cd /e/fqapp-build2 && flutter build apk --release --target-platform android-arm64 --dart-define=fqapp.debugTools=true

正式构建（无调试页）：
  flutter build apk --release --target-platform android-arm64

装机：
  ADB=/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe
  $ADB -s b2f8e975 install -r build/app/outputs/flutter-apk/app-release.apk
  $ADB -s b2f8e975 shell am start -n com.fqapp.fqapp/.MainActivity

- keystore 密码在 E:\项目\青茄阅读\signing\SIGNING-SECRETS.txt；android/keystore.properties 是 git 忽略的本地文件。
- ~/.gradle/gradle.properties 里的 VPN 代理（127.0.0.1:51981）已被注释——仓库走阿里云镜像可直连。若用户开了 VPN 导致构建失败，按文件内注释改回端口。
- APK 归档惯例：cp <apk> /d/APP/agent/apk/fqapp-vNN.apk（最新 v67 = 1.0.132+137）。
- debugTools 开关：--dart-define=fqapp.debugTools=true 让调试页（手写笔探测/批注诊断）出现在 release 包；签名与正式包一致，可直接覆盖安装再换回。

### 1.4 Git 与推送（重点：Windows 侧没有凭据）

- Windows 侧 git push 不可用：无 gh CLI、无 token、直连 github.com 被断（pdfium 预编译下载走 ghproxy.net 镜像）。
- 推送必须走 WSL（原机凭据都在里面）：

  wsl -d Ubuntu-24.04 -- bash -c "export PATH=/home/fy/.local/bin:\$PATH; cd /mnt/e/项目/青茄阅读/repo/fqapp-src && git push origin master"

  （WSL 内 gh 已登录 fangyuzhang，ghproxy 镜像规则在 WSL 的 ~/.gitconfig。仓库本地 credential helper 用了裸 gh，必须先 export PATH，否则 Invalid username or token。bash -c 外层的 Windows PATH 混入会报一条 export 错误——无害，忽略。）
- 推送后校验：git ls-remote origin master 与 git rev-parse HEAD 一致（连接重置就重试一次，本会话两次成功前各重试过）。
- git 身份已配：青茄阅读 <dev@qingqie.local>（仓库本地 config）。
- 提交规范（AGENTS.md）：area: 结果，正文写 为什么/怎么验/影响面。

### 1.5 真机验证手法（视觉取证链）

- 截图：$ADB exec-out screencap -p > x.png，用 python PIL 做像素分析（定位按钮/对比前后帧/按颜色聚类找中心）。
- **MIUI screencap 旧帧陷阱**：拖拽/动画进行中或刚结束时，screencap 可能返回陈旧合成帧（多张字节级相同即中招）。对策：改用语义树断言（uiautomator dump + cat）或等 2s 再截；关键状态用 ui.py 的 desc/text 定位而非像素。uiautomator dump 的 bounds 是物理像素（×dpr=3 于逻辑坐标），input tap 直接可用。
- **手势注入限制**（MIUI Android 11）：
  - `input swipe` 立即移动 → 时间线/横向滚动容器会抢 Arena，LongPressDraggable 拖拽不起（调色板行的组拖删无法用 swipe 注入）；
  - `input motionevent` 不支持（Android 12 才有）；
  - `input draganddrop` 对**笔记角标**有效（已验证删除成功），对**调色板 chip**（水平滚动容器内）无效；
  - 系统文件选择器（DocumentsUI）：搜索/菜单/抽屉/筛选 chip 可注入，**文件项点击无效**（SAF 手测留人工）；
  - 通知栏展开时先 `cmd statusbar collapse`。
- dumpsys gfxinfo 对 Flutter 自绘 surface 统计恒 0 帧（MIUI Android 11 限制），帧率取证不可行。
- 证据截图归档：E:\项目\青茄阅读\releases\glass-theme-shots\。

### 1.6 脚本/工具坑（改代码时）

- python heredoc 陷阱：python - <<'PYEOF' 里的中文长段/反引号/反斜杠会被 bash 吞导致锚点失配或命令替换。改文件一律用 Write 写 .py 临时文件再 python file.py，跑完删除。
- Edit 工具锚点必须字节级精确（注意 en-dash、中文标点）；大范围删除区间前先用括号配平扫描（剥离字符串/注释后数括号）确认边界，删完必须立即 analyze——本会话两次事故（reader_page 误删 5 个方法；notes_page 徽标段重写吞掉引文/想法块）都是删区间过宽，靠 analyze/对照读回定位修复。
- git checkout -- <file> 恢复单文件时注意：基线之前的 HEAD 是旧代码，会连带丢掉该文件上的近期批次改动。恢复前先 git diff <file> | grep "^-" 确认要丢什么。
- 测试视口陷阱：widget 测试默认 800×600，sheet 底部内容会滚出屏（startGesture 打在屏外，拖拽不起）——先设 `tester.view.physicalSize = Size(1080, 2400); devicePixelRatio = 3.0`（本会话编辑器垃圾桶测试踩过）。

---

## 2. 当前代码形态

### 2.1 架构与主题

- AppTheme.createTheme(brightness, {einkMode})（lib/services/app_theme.dart）+ 顶层 themeModeNotifier / einkModeNotifier；HomePalette（widgets/home/home_design.dart）是取色中枢：accent=0xFF2FA98C，muted=#5E6B64。
- 状态存储：Hive CE（加密 EncryptedHive.openBox）+ SharedPreferences + Android Keystore（flutter_secure_storage）；Flutter UI 经 flutter_rust_bridge 调进程内 Rust 核心 fqapi_core（127.0.0.1:8080 loopback）。
- 首页 PageView 融合导航（v51）：第 0 页推荐视图，第 1–7 页各分类全部书城。

### 2.2 阅读器（lib/pages/reader_page.dart，~4600 行）

- 章节文本链路：_chapterText → ReadableChapterResolver → 内存 LRU（5 章）→ ChapterCacheStore（加密盒）→ ApiClient（在线）或 chapterLoader（本地书）→ ChapterContent.fromCacheText。
- 排版/分页引擎：lib/widgets/reader/reader_chapter_layout.dart（TextPainter 逐行量高，_paginate 切页）；分页/滚动双模式共享同一测量。
- 进度：ReaderHistory → LibraryStore 'history' 盒（positionVersion:2 = textOffset 字符偏移）。
- **手写批注模式（第 6 组）**：分页模式下 ReaderControls「手写」入口 → _enterInkMode（排版版本定格 layoutVersion = 字号/缩放/视口/页号指纹）→ InkCanvas/InkToolbar 叠加 → 墨迹 = 归一化坐标 + 页文本区间锚点（page.start/end + 32 字符指纹）双写 InkAnnotationStore；退出后锚点区间以虚线并入 _annotationRanges 投影（ReaderBlockMarkPainter 通道，分页/滚动都显示）；「墨迹」列表入口（缩略图 + 锚点状态 + 跳转）。
- ⚠️ 正文路径是优化期红线：reader_page 的批注挂载全部为附加式插入（_ink 非空时 Stack 叠画布、菜单换 InkToolbar），分页/滚动/进度逻辑零改动——后续改这里必须维持。
- 拖拽期铁律（真机事故）：InkCanvas 的 dragDevices 静态收紧为 touch-only，**不得随批注模式切换重包 ScrollConfiguration**——那会重建 PageView 子树使 pdfrx 纹理失效 → MIUI 渲染面冻结白屏；批注进出也不得切 SystemUiMode（v49 同族坑）。

### 2.3 PDF 阅读器（lib/pages/pdf_reader_page.dart）

- `pdfrxFlutterInitialize()` 先行（幂等，设缓存目录）→ PdfDocument.openFile → PageView + PdfPageView 渲染原版式；左右点击区翻页、中间切换工具栏、页码滑杆。
- 批注模式：InkCanvas 只收 stylus（touch 穿透翻页——dragDevices 静态收紧为 touch-only，**不得随模式切换重包 ScrollConfiguration**，那会重建 PageView 子树使 pdfrx 纹理失效 → MIUI 渲染面冻结白屏，已实测）；批注进出不得切 SystemUiMode。
- 墨迹整页一条 InkAnnotation（bookId + pdf:page:N + pdf-fixed）；锚点 = 墨迹包围盒与 PDFium 字符矩形求交 → 字符区间 + 32 字符指纹 + 锚点盒归一化；无文本层退化为纯页锚点（unverified）。
- 进度 positionVersion:3（page/pageCount）存 LibraryStore 历史盒。
- pageText() 暴露逐字符坐标表（AnchorProjector 的输入）。

### 2.4 笔记页（lib/pages/notes_page.dart，~2400 行）

- 类型筛选：全部/批注/书摘/划线/**手写**（NoteTypeFilter.ink，InkAnnotationStore.loadAll 直读，SizeTransition 生长动画）；「全部标签」行 = 批注类型 + 自由标签（可长按拖动换序，行高 20）。
- **标签拖拽垃圾桶**（66 批）：任何标签长按拖动 → 顶部浮现垃圾桶（overlay + 径向暗化，近桶最暗越往外越清）；笔记角标拖入 = 从该笔记摘除；调色板标签拖入 = 从所有笔记摘除 + 自定义类型移出目录（内置预设保留目录但笔记上摘净）；多选磁吸组（选中 ≥2 枚时长按任一枚）整组跟手拖入垃圾桶全删。
- **拖出落空 = 弹回原位不删除**（旧「拖出即删」已取消）。
- 角标行 growth：SizeTransition + TweenAnimationBuilder（空→非空翻转时 220ms 展开）——不要用 AnimatedSize（IntrinsicHeight 内会以动画中间值当行高导致内容溢出断言）。
- 手写时间线：日期轴 + 墨迹缩略卡（InkStrokesPainter），点行跳转（PDF 直达页/流式书按锚点偏移）。

### 2.5 关键状态机（notes_page 调色板拖拽）

- `_dragGroup`：当前磁吸组成员（空 = 无调色板拖动；≥2 = 磁吸组负载）；`_dragSource`：被拖起的那一枚；`_dragAbsorbEnabled`：仅单枚拖起为 true。
- **铁律：被拖起的那枚 chip 拖动期间必须保持 Draggable 活着**——hidden 槽位判定必须排除 _dragSource，否则 onDragEnd 丢失、_dragGroup 永不复位，级联出：空位不回填/垃圾桶不消失/后续拖删全失效/滑动误吸收（本会话最大事故，已修）。
- 吸收仅在拖出行后触发（`!inRow`）；行内是换序语义。
- 收尾（_paletteDragFinished）必须复位 _dragGroup/_dragSource/_dragAbsorbEnabled。
- 批注编辑器（showAnnotationEditor）标签 chip 同套交互：拖入 sheet 顶部垃圾桶（key reader-tag-trash）即从待存标签移除，X 保留；编辑器测试需设高视口（默认 800×600 时 chip 滚出屏，startGesture 打在屏外拖拽不起）。

### 2.6 存储一览（加密 Hive，EncryptedHive.openBox）

| 盒 | 内容 | key |
| --- | --- | --- |
| reader_ink_annotations_v1 | 手写墨迹（整页一条） | ink:bookId:chapterId:layoutVersion |
| reader_annotations_v1 | 批注/书摘 | jsonEncode(['a',bookId,chapterId,start,end]) |
| reader_underlines_v1 | 划线（整段+范围） | 见 reader_underline_store.dart |
| history | 阅读进度 | 书 id（positionVersion:2 文本偏移 / :3 PDF 页码） |
| chapter_cache_v1 | 章节离线缓存 | chapter:[bookId,chapterId] |

- 墨迹**读路径走 `_read`（直接单飞 _box，不入写队列）**——写队列的 _writes 链横跨 fake-async 测试 zone 后新用例 await 永不完成（notes 页测试曾批量挂起）。写路径仍串行 + flush。
- library_store.dart 的 init() 必须置 `InkAnnotationStore.hiveReady = true`（漏接则读写全部空转——与 ReaderAnnotationStore 同款坑，67bb55f 前已修）。

---

## 3. 调试设施

- **debugTools 开关**：lib/services/debug_tools.dart —— `--dart-define=fqapp.debugTools=true`；调试页挂设置→服务（kDebugMode 或该 define）。
- **手写笔探测页**（stylus_probe_page）：真机实测 kind/pressure/tilt/orientation；K20 Pro 手指实测 pressure 恒 1.0、tilt 恒 0（结论回填文件头）。
- **批注诊断页**（annotation_diagnostics_page）：全部墨迹的锚点状态（命中/部分/失配/未校验）+ 存储统计行（box/entries/盒文件字节）+ 轨迹（logTrace 双通道：内存环 + AppLog 'ink' 标签——release 观测走日志查看器，print 不落 logcat）。
- **日志查看器**：设置→服务→日志，按「应用」筛选可看 AppLog.w('ink', ...) 轨迹。

---

## 4. 验证门槛（每小步）

- flutter analyze：0 error / 0 warning / 0 info（ASCII 副本 E:\fqapp-build2 执行）。
- flutter test：1546 通过 / 10 跳过 / 0 失败。
- 真机：b2f8e975（Redmi K20 Pro）。构建产物 .so 完整性：libfqapi_core.so 6,444,168 字节 + libpdfium.so 16KiB 对齐。
- 测试视口：widget 测试默认 800×600，sheet 底部内容会滚出屏——先设 tester.view（见 reader_annotation_sheet_test 的编辑器垃圾桶用例）。

---

## 5. 遗留任务（按优先级）

1. **MatePad 11 + M-Pencil 3 实测**（设备未到位）：pressure 范围/tilt/书写帧率 ≥50fps；工具栏「手指绘制」开关仅调试构建可见。
2. **SAF 手选导入 PDF 人工手测**：文件选择器文件项点击不被 adb 注入命中（代码与 ACTION_VIEW 通道同路）。
3. **调色板行磁吸组拖删真机手指复验**（语义由 widget 测试锁定；adb 注入被水平滚动容器抢 Arena）。
4. 多选磁吸组的「吸附后贴合/重合」视觉可再打磨（当前错位叠放已可用）。
5. 用户要求过的「书名与章节距离减半」已落地（行高 20 + 图标 15）——若仍嫌挤，可再收padding，但不得低于图标高度（防重叠回归）。

---

## 6. 禁改区与护栏

- rust/、native/、lib/src/rust/（FRB 生成物）、android 构建协议代码、lib/widgets/reader/reader_theme.dart（正文背景）、正文绘制/分页/滚动/书签/进度路径。
- 技术锁：FRB 2.13.0、仅 arm64-v8a、16KiB 对齐、pdfrx >=2.2.0 <2.3.0、不引入新状态管理/路由/UI 框架包。
- 完整清单见 OPTIMIZATION-GUARDRAILS.md 与 AGENTS.md；界面约定见 README.md（改 UI 前必读）。
