# 轻读 Agent 交接文档

> ## 本文是历史归档，不是当前状态
>
> 当前状态请看 **[`AGENT-HANDOVER-NEXT.md`](AGENT-HANDOVER-NEXT.md)**，逐批改动看 **[`QINGDU-CHANGES.md`](QINGDU-CHANGES.md)**。
>
> 本文记录的是 2026-10-23 之前那一轮「正文沉浸态 + 全局日夜联动」的完整实现过程，其中的路径、HEAD、测试数字、工作树描述都已过期，**只作为功能背景与踩坑记录阅读**。特别是下面这些说法已经不对：
>
> - 项目路径已迁到 WSL 原生 `/home/fy/projects/fqapp-src`，不再是 `C:\Users\...\WorkBuddy\...`；
> - 工作树已干净，所有改动都已提交并推送到私有仓库 `fangyuzhang/qingqie-reader-app`；
> - 测试基线是 1488 通过 / 10 跳过 / 0 失败，不是文中的旧数字；
> - 版本仍是 `1.0.129 (134)`，包名 `com.fqapp.fqapp`（这两项没变）。

> 归档时间：2026-10-23
> 归档时的 HEAD：`047c9c73563e7c2a936abd746b8f02e4a86503eb`（仅作历史标记）
> 分支：`master`

## 0. 首先必读（归档上下文）

1. **文中「工作树有大量未提交修改」指的是当时那一刻**，现已全部提交；但 `git reset --hard` / `git checkout .` / `git clean` 在任何时候都不要随手执行。
2. 本项目只做小说与听书。短剧、漫剧、漫画、视频能力属于已收口范围，不要因为看到历史文件或 `shortplay` 命名就恢复它们。
3. 不要用“猜测 PIN、绕过锁屏”的方式操作真机；如设备锁定，等用户手动解锁。
4. 那一轮的 commit / push 已在后续批次补齐，本文的「未提交」表述仅描述当时状态。
5. 临时探测文件不要提交进仓库。

## 1. 当前交付状态

已完成并验证：

- 手机端点书停留在书籍详情/目录，不自动跳正文。
- 笔记带时间戳、自定义分类、多标签。
- 笔记支持按书籍、时间、分类、标签单独或组合筛选。
- 划线支持实线、虚线、波浪线、荧光笔，并记忆上次选择。
- 批注支持疑问、反驳、感悟、待查证，文字和底色可自定义。
- 笔记时间线回顾。
- 笔记页支持“时间线 / 按书查看”切换，可按书查看一本书的全部笔记。
- 首页推荐每天轮换、支持“换一批”、下拉刷新轮换。
- 分类“全部”从书城按多个关键词加载真实书目，支持加载更多和换一批。
- 分类页不再自己闪刷一遍：首屏结果追加合入，只有「换一批」才整体替换。
- 详情页首屏不再等两个请求：detail 先到先上屏 + 详情快照同帧渲染。
- 阅读页不再等整本目录落盘：正文落盘转后台，偏好/进度并行读取，插图提前预热。
- 详情页停留时预热续读章节正文与插图，点进去正文 843ms → 23ms；无划线/批注/段评时不再多余整章重排。
- 空正文根因治理：书名页、卷页等标题占位页自动跳到后续真实正文。
- 上下滚动模式跨章无缝：章首往下拖直接接上一章末尾，窗口只增不减、不再整块重建跳位。
- 笔记页三视图（时间线 / 按书查看 / 划线）：「按书查看」用与首页一致的封面网格；划线视图合并范围划线与整段划线，可按线型与书过滤并直达原句。
- 自定义批注类型：编辑器内置 4 预设 + 现场新增（自命名 + 取色，加密 Hive 记忆最多 24 条），笔记页可按批注类型筛选。
- 划线预选修复：点「划线」出现预选面板后点正文别处，按当前线型/颜色直接落笔（面板另带确定/取消）。
- 全应用锁定竖屏：手机横过来界面不再转横排；`main.dart` 调 `SystemChrome.setPreferredOrientations([portraitUp])`，`MainActivity` 另带 `android:screenOrientation="portrait"` 兜底，启动瞬间即为竖屏。
- 听书详情页重构：小封面在左上、右侧显示当前章节；整章文字可上下滚动，当前句高亮并自动跟随；长按任意一句可「从本句听」；下方显示「第 X / Y 页」与「全书 NN.N%」；句子长短不再推挤播放控件。
- 正文朗读句高亮：字幕句整句对位着色，跨段落/对不上原文时按进度整段兜底；暂停时保留，停止听书才清空。
- 听书悬浮胶囊：232×48 可拖动悬浮窗，保留暂停与关闭，新增「听书设置」（定时关闭 / 语速 / 音色）。
- 听书胶囊双形态：阅读页工具栏展开时显示完整可拖动胶囊，工具栏收起时收紧为底部 128×38 小按钮（「停止听书 / 继续听书」）。
- 护眼提醒置顶：连续阅读 45 分钟弹出提醒，弹窗期间听书胶囊不渲染，弹窗完整覆盖页面元素。
- 切章音频链路：锁章提示「本章为付费内容，暂不可听。」、无音源提示「本章暂无音频内容。」；无音源前置页自动跳过（锁章不跳过）；用户切章遇无音频时自动转系统朗读并落到该章正文页（不再退回详情页）；修复系统朗读空正文误判。
- 系统朗读与作品自带音频共用同一套听书详情页：小封面 + 当前章节、整章逐句可滚正文、页码/全书进度、固定状态行（「正在朗读 · 第 i / N 句」）、目录/上下章/播放/朗读设置、底部音色条。
- 系统朗读逐句送引擎：`SystemTtsPlayback.speakFrom/sentenceRange` 每次只把一个分句交给 TTS，正文高亮严格跟当前句，不再整段或整段以上一起亮。
- 听书正文小窗上下渐隐（`NarrationFade` 44px，`stops [0, 0.28, 1]`），首末行淡出，不再硬切半行。
- 正文左下角改为「读到 X 页 · 共 Y 页 · 剩 Z 页」，右侧保留「全书 NN.N%」。
- 收起态胶囊贴安全区上沿（`bottom: padding.bottom + 4`），整颗落在状态行内，不再一半压正文、一半压手势条。
- 弹层期间胶囊隐身：`AudioRouteWatcher.popupOpen` 命中 `PopupRoute` 时整体隐藏，「听书 / 系统朗读」选择面板不再被胶囊遮挡。
- 听书底部「继续听书 / 停止听书」小药丸已删除，只剩可拖动胶囊。
- 阅读状态行：左下角「9/1048 0.8%」，右下角电池图标 + 百分比；行高固定，切日夜正文不跳。
- 沉浸式阅读：工具栏收起时隐藏系统状态栏与手势条（immersiveSticky），工具栏/弹层/离开页面时恢复 edge-to-edge。
- 行内批注按批注行插入：批注卡片在该行之后，后续正文从下一行继续。
- 听书跟随改为按真实行位置定位 + 380ms 缓动，高亮行始终留在视口内。
- 阅读工具栏右上角改为「加入书架」；详情页底栏为「加入书架」（加大）、右上角为「下载」。
- 长按选区菜单常驻「从本段开始听书」。
- 关闭听书后返回直接回到小说详情，不再出现「本次播放已关闭」黑屏页。
- TTS、整本下载、TXT 导出复用统一正文解析器。
- 旧版“结构化空缓存”可自愈，不再永久卡在“正文为空”。

## 2. 当前 APK 与真机

- APK：`build/app/outputs/flutter-apk/app-release.apk`
- 版本：`1.0.129 (134)`
- 大小：38,524,635 字节（36.7 MiB）
- SHA-256：`840078ba1bcd93ff42d5eb3a5f02548958f78ae8ab910604ca7bb6aa9717660d`
  （2026-10-23 11:48 由 WSL 原生路径构建，含「工具栏显隐不再推动正文」：冻结安全区 + 章首按实测工具栏高度让位 + 滚动偏移补偿；版本号未变，旧值 `d64dd77f…` 为 v24 含沉浸式系统栏、状态行页码/电量、批注行内落位、听书跟随缓动、工具栏与详情页按钮重排、选区菜单常驻听书、关闭听书返回修复；`55b42d4b…` 为 v23 包含系统朗读听书页同构/逐句高亮/正文渐隐/页码胶囊落位；`397e5e5c…` 为 v22 包含听书胶囊双形态/护眼弹窗置顶/切章音频链路；`12fdebd…` 为 v21 包 由 WSL 原生路径构建，含听书页重构：固定布局、可滚正文、从本句听、页数/全书进度；版本号未变，旧值 `b4faa47f…` 为 v21 中间包、`4079ef3e…` 为 v20 包、`68df0127…` 为 v19 包、`15b65a77…` 为 v18.1 包、`544d844e…` 为 v17 包、`ee872b28…` 为 v16 包、`4a3a915c…` 为 v15 包、`2f0154f2…` 为 v14 包、`5cd72e4d…` 为 v13 包）
- 签名证书 SHA-256：`46393428a5041ba335a81ce56d7d8ab72753a19c0593a1ae669b30cf03a6e00b`
- 验证报告：`build/ci-artifacts/verification/report.json`（2026-10-23 09:57 校验通过：ELF 对齐 / zipalign / apksigner / aapt badging）

真机：

- 设备：Redmi K20 Pro
- 序列号：`b2f8e975`
- ADB 当前已连接。
- 覆盖安装成功，未卸载、未清除数据。
- `firstInstallTime=2026-10-19 23:07:26` 未变化。
- `lastUpdateTime=2026-10-23 11:50:39`（v25 工具栏显隐不再推动正文：冻结安全区 + 章首按实测工具栏高度让位 + 滚动偏移补偿）。
- `lastUpdateTime=2026-10-23 09:58:48`（v24 沉浸式系统栏 + 状态行页码/电量 + 批注行内落位 + 听书跟随缓动 + 按钮重排 + 关闭听书返回修复）。
- `lastUpdateTime=2026-10-23 08:40:36`（v23 系统朗读听书页同构 + 逐句高亮 + 正文渐隐 + 页码与胶囊落位 + 弹层期间胶囊隐身）。
- `lastUpdateTime=2026-10-22 23:02:46`（v22 听书胶囊双形态 + 护眼弹窗置顶 + 切章音频链路修复）。
- `lastUpdateTime=2026-10-22 21:22:51`（v21 听书页重构：固定布局 + 可滚正文 + 从本句听 + 页数/全书进度）。
- `lastUpdateTime=2026-10-22 19:55:06`（v20 听书详情/正文联动 + 句级高亮 + 悬浮胶囊构建）。
- `lastUpdateTime=2026-10-22 18:42:46`（v19 全应用锁定竖屏构建）。
- `lastUpdateTime=2026-10-22 18:37:43`（v18.1 我的/设置/统计收口到同一色系构建）。
- `lastUpdateTime=2026-10-22 17:52:51`（v18 听书配色语言统一到其余界面构建）。
- `lastUpdateTime=2026-10-22 17:29:51`（v17 笔记重构 + 自定义批注类型 + 划线查看 + 划线预选修复构建）。
- `lastUpdateTime=2026-10-22 13:53:43`（v16 上下滚动向前跨章无缝构建）。
- `lastUpdateTime=2026-10-22 13:22:50`（v15 骨架屏 + 分类预热 + 插图解码尺寸构建）。
- `lastUpdateTime=2026-10-22 13:03:59`（v14 实测后二次提速构建）。
- `lastUpdateTime=2026-10-22 12:40:05`（v13 分类/详情/阅读提速构建）。
- `lastUpdateTime=2026-10-22 11:12:17`（v12 分类页缓存构建）。
- `lastUpdateTime=2026-10-22 09:40:49`。
- 验收后 App 停留在「首页」（最后一次覆盖安装后重启）。
- logcat 错误扫描为 0：无崩溃、未处理 Flutter 异常或 ANR。

归档：

- `release-archives/v11/`
- 包含 APK、APK 校验报告、全量测试日志、真机截图/UI XML、验收记录、SHA256SUMS。

## 3. 本轮关键实现

### 3.1 空正文根因治理

核心文件：

- `lib/services/readable_chapter_resolver.dart`
- `lib/services/chapter_text_formatter.dart`
- `lib/pages/reader_page.dart`
- `lib/services/system_tts.dart`
- `lib/services/chapter_download.dart`
- `lib/services/book_txt_export.dart`

根因：上游目录把书名页、卷页、版权页、推荐信等混在普通章节中。《老人与海》目录项“老人与海”的接口正文只有标题，真实正文在下一项。

处理规则：

- 去掉首标题后完全无正文：标题占位页，跳到下一目录项。
- 图片页、版权页、真实短正文：保留。
- 真正空响应、网络失败、解密失败、缓存格式错误：明确报错，不伪装成占位页。
- 最多扫描 8 个候选目录项。
- 阅读器、TTS、下载、导出共用同一解析语义。

旧缓存自愈：

- 阅读器不再把“结构化空缓存”当作权威离线内容。
- 空结构化缓存会自动失效并重新联网。
- 回归测试：`test/reader_page_test.dart` 的 `a poisoned empty structured cache is refetched`。

### 3.2 首页推荐轮换

文件：

- `lib/models/curated_book.dart`
- `lib/pages/home_page.dart`

行为：

- `CuratedCatalog.pickOfDay` 按日期稳定轮换，同一天稳定、跨天不同。
- `recommendationBatchOf` 按分类生成每日批次；`batch` 响应“换一批”。
- 首页每分类推荐位显示 4 本，完整分类入口仍可查看全部。
- 下拉刷新也会推进推荐批次。

### 3.3 分类“全部”接入书城

文件：

- `lib/pages/category_browse_page.dart`（新增）
- `lib/pages/home_page.dart`
- `test/category_browse_page_test.dart`（新增）

行为：

- 首页顶部分类标签、分类入口按钮、分类栏“全部”都打开 `CategoryBrowsePage`。
- 分类页预置多组相关关键词，并行请求 `ApiClient.searchTabs(query, tabType: 3, offset: ...)`。
- 结果按书籍 ID 去重，单关键词失败不影响其他关键词。
- 首次批量、加载更多、换一批都可用。
- 全部关键词失败时显示重试入口。
- 当前内置的 6 本仍显示为“精选”，但分类页是书城扩展结果。

真机结果：

- 古典名著：40 本；换一批后 44 本。
- 世界文学：41 本。
- 历史人文：32 本。
- 科普百科：40 本。
- 科幻想象：44 本。
- 成长青春：45 本。
- 诗歌散文：44 本。

### 3.4 笔记功能

文件：

- `lib/pages/notes_page.dart`
- `lib/services/note_timeline.dart`
- `lib/services/reader_annotation_store.dart`
- `lib/services/reader_mark_style.dart`
- `lib/services/reader_mark_preferences.dart`

功能：

- 时间戳、自定义分类、多标签。
- 书籍/时间/分类/标签组合筛选。
- 时间线视图。
- “按书查看”视图，显示每本书的笔记数、批注数、书摘数、章节数。
- 点击一本书后自动切回时间线并应用 `bookId` 筛选。
- 划线四种样式：实线、虚线、波浪线、荧光笔。
- 批注类型、角标文字和底色可编辑。
- 划线样式会记忆上次选择。

## 4. 验证记录

最近一次验证：

- `flutter analyze --no-pub`：`No issues found!`
- Flutter 全量测试：`1472 passed / 10 skipped`（v17 批次，含 `notes_page_test` 4 项、`reader_marker_type_store_test` 4 项、`reader_paragraph_actions_test` 新增的划线预选 2 项）

注意：本仓库历史代码是**旧格式化风格**。本机 `dart format` 默认按 tall style（Dart ≥3.7）
重排，直接 `dart format lib test` 会改写上百个无关文件。格式化必须带
`--language-version=3.6`：

```bash
dart format --language-version=3.6 lib/pages/reader_page.dart
```

历史记录（v11 时期）：

- Flutter 全量测试：`1457 passed / 1 skipped`
- 分类页与首页定向回归：`26 passed`
- APK：签名、签名证书、ABI、版本、原生库、ZIP/ELF 16 KiB 对齐全部通过
- 真机：安装、启动、分类加载、换一批、笔记按书查看均验证
- 真机 logcat：错误扫描 0

测试日志：

- `build/test-v11-full.log`
- `release-archives/v11/flutter-test-full.log`

## 5. 构建环境与命令

成功构建环境：

```powershell
$env:FLUTTER_PREBUILT_ENGINE_VERSION='d8a2d6c768c334d53e16277f837970ffa1e2de81'
$env:GRADLE_USER_HOME='C:\Users\zjh30\AppData\Local\Temp\fqapp-gradle-clean-20261021'
$env:ANDROID_HOME='D:\APP\DevTools\Android\Sdk'
$env:ANDROID_SDK_ROOT=$env:ANDROID_HOME
$env:JAVA_HOME='D:\APP\DevTools\JDK'
$env:PUB_CACHE='C:\Users\zjh30\AppData\Local\Temp\fqapp-pub-cache-20261021'
$env:PUB_HOSTED_URL='https://pub.dev'
```

构建：

```powershell
.\tool\build_release.ps1 -SkipRustBuild -GradleUserHome $env:GRADLE_USER_HOME
```

安装：

```powershell
$adb='D:\APP\DevTools\Android\Sdk\platform-tools\adb.exe'
& $adb -s b2f8e975 install -r 'build\app\outputs\flutter-apk\app-release.apk'
& $adb -s b2f8e975 shell am start -W -n com.fqapp.fqapp/.MainActivity
```

### 全量测试的端口注意事项

`test/rust_host_integration_test.dart` 会监听本机 8080。若此前执行过以下命令：

```powershell
adb -s b2f8e975 forward tcp:8080 tcp:8080
```

全量测试可能出现：

```text
listen 127.0.0.1:8080: 通常每个套接字地址只允许使用一次。 (os error 10048)
```

处理：

```powershell
adb -s b2f8e975 forward --remove tcp:8080
flutter test --no-pub --reporter compact
adb -s b2f8e975 forward tcp:8080 tcp:8080
```

这是测试环境端口冲突，不是正文代码缺陷。

## 6. 工作树现状与注意项

`git status` 当前为大规模 dirty，包含：

- 本轮新增和修改。
- 用户此前的大范围产品收口：删除短剧/漫剧/漫画/下载与播放器相关文件。
- 已有本地探测数据。
- 依赖调整。

本轮相关新增未跟踪文件：

- `lib/pages/category_browse_page.dart`
- `test/category_browse_page_test.dart`
- `lib/services/readable_chapter_resolver.dart`
- `lib/services/note_timeline.dart`
- `lib/services/reader_mark_preferences.dart`
- `lib/services/reader_mark_style.dart`
- `test/readable_chapter_resolver_test.dart`
- `test/note_timeline_test.dart`
- `test/reader_mark_style_test.dart`

本轮相关修改文件：

- `lib/models/curated_book.dart`
- `lib/pages/home_page.dart`
- `lib/pages/notes_page.dart`
- `lib/pages/reader_page.dart`
- `lib/services/system_tts.dart`
- `lib/services/chapter_download.dart`
- `lib/services/book_txt_export.dart`
- `lib/services/chapter_text_formatter.dart`
- `lib/pages/about_page.dart`
- `pubspec.yaml`
- `QINGDU-CHANGES.md`
- 对应测试文件

依赖状态：

- `pubspec.lock` 仅保留有意变化：移除 `lottie`，`fake_async` 从直接 dev 变为传递依赖。
- 不要为了“干净”随意恢复锁文件；先确认依赖配置。
- 构建时 Flutter 工具可能打印 “Running pub upgrade”，构建后必须复查 `git diff -- pubspec.lock`。

根目录探测文件：

- `candidates.txt`
- `content-*.json`
- `detail-oldman.json`
- `dir-oldman.json`
- `huozhe_candidates.txt`
- `inspect_huozhe.txt`
- `probe_books.txt`
- `search-book.json`
- `search-laorenyuhai.json`
- `screen-current.png`
- `window*.xml`
- `$null`（误生成的临时文件）

这些不是应用运行依赖。除非用户明确同意，不要删除。

## 7. 已知风险与后续建议

1. **分类结果相关性**：当前用多个关键词召回，可能带出“历史人物/古典合集”等边界书目。下一步可增加分类白名单、标题/简介关键词评分或人工黑名单。
2. **请求量**：每次分类批次会并行请求多个关键词。可增加分类结果短期缓存，减少重复请求和等待。
3. **去重粒度**：当前按书城条目 ID 去重；同一本书的不同版本/全集仍会同时出现。若用户要求，可再按归一化标题+作者聚合。
4. **分页边界**：分类页用 offset 分页；“换一批”到末尾会回绕首页批次。若上游 offset 不稳定，建议记录 cursor 而不是仅依赖偏移。
5. **未提交基线**：工作树包含用户既有改动，提交前必须逐文件审查，不要把用户改动误归为本次任务。
6. **跨章长按选区**仍是独立已知限制：选区几何表按块下标建键会跨章冲突。
7. 若继续发布：先跑全量测试、构建脚本、APK 校验、真机安装和历史数据保留检查，再更新 `QINGDU-CHANGES.md`，重新生成归档和 `SHA256SUMS`。
8. 若接入新的分类来源，优先复用 `CategoryBrowsePage` 的加载器接口，不要绕开它直接在某一个页面里写另一套请求/去重逻辑。

## 8. 快速接手检查清单

```powershell
cd 'C:\Users\zjh30\WorkBuddy\2026-10-19-08-17-51\fqapp-src'
git status --short --untracked-files=all
git rev-parse HEAD
flutter analyze --no-pub
flutter test --no-pub test/category_browse_page_test.dart test/home_page_test.dart
flutter test --no-pub test/reader_page_test.dart test/readable_chapter_resolver_test.dart test/chapter_download_test.dart test/book_txt_export_test.dart test/system_tts_test.dart
```

如果设备连接：

```powershell
$adb='D:\APP\DevTools\Android\Sdk\platform-tools\adb.exe'
& $adb devices -l
& $adb -s b2f8e975 shell dumpsys window | Select-String 'mCurrentFocus|isKeyguardShowing'
```

## 9. 参考文档

- `QINGDU-CHANGES.md`：按批次记录 v5 到 v11 的变更、验证和已知限制。
- `DEVELOPMENT.md`：架构、目录、构建入口和开发边界。
- `release-archives/v11/VERIFICATION.md`：本轮构建验证摘要。
- `release-archives/v11/device-acceptance/ACCEPTANCE.md`：本轮真机验收记录。
- `AGENTS.md`：项目协作约束。

## 附：WSL 原生开发环境（2026-10-22 建立）

Windows 盘（`/mnt/c`、`/mnt/d`）走 9p，Codex 在 WSL 侧做 `rg`/`git`/读写补丁时明显卡顿
（实测 `git status` 2.7 秒、`du -sh .` 约 5 分钟）。已在 WSL 原生 ext4 建好完整构建链：

- 源码副本（建议作为工作主线）：`/home/fy/projects/fqapp-src`（含 `.git` 与全部未提交改动）
- Flutter SDK：`/home/fy/flutter`（3.47.7 stable / Dart 3.13.5，来自腾讯云镜像）
- Android SDK：`/home/fy/Android/Sdk`（platform 36、build-tools 36.0.0、NDK 28.2.13676358、CMake 3.22.1，Linux 版）
- JDK：`/home/fy/jdk17`（Temurin 17.0.20.1，清华 Adoptium 镜像）
- Rust：`~/.cargo`（1.99.1，rustup 走清华镜像，crates 走清华 sparse index，已装 `aarch64-linux-android`）

环境变量已写入 `~/.bashrc`（`FLUTTER_ROOT`/`PUB_HOSTED_URL`/`ANDROID_HOME`/`ANDROID_NDK_HOME`/`JAVA_HOME`）。
镜像选择依据实测速度：Flutter SDK、Android SDK、Gradle 用腾讯云（8–9 MB/s），Rust 用清华（6 MB/s），
pub 用 `pub.flutter-io.cn`。

原生构建命令（等价于 `tool/build_release.ps1 -SkipRustBuild` 的 Dart 部分）：

```bash
cd ~/projects/fqapp-src
./scripts/build_rust_backend.sh --skip-codegen   # 仅 Rust 有改动时需要
flutter build apk --release --target-platform android-arm64 --no-pub
```

注意：

- `android/keystore.properties` 在本副本里改成了 Linux 路径（`/mnt/c/.../release-signing/qingqie-release.jks`），该文件被 git 忽略。
- `pubspec.lock` 因 `PUB_HOSTED_URL` 指向国内镜像，`url:` 字段会写成 `pub.flutter-io.cn`；不要把这份锁文件同步回 Windows 副本。
- adb 仍走 Windows（`adb.exe`）。WSL 的 adb 连不上 Windows 的 5037（防火墙），如需纯 WSL 装机要用无线调试 `adb pair`。
