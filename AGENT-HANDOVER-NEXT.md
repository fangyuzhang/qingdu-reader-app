# 交接文档：我的页「阅读热力图 / 每日记录」合并（含代码精简）

> 生成时间：2026-10-23
> 仓库：`/home/fy/projects/fqapp-src`（WSL2 原生路径，**不是** `/mnt/c` 上的副本）
> 分支：`master`　HEAD：`9d20ecb`（工作区干净）
> 上一份总交接文档：`AGENT-HANDOVER.md`（历史版本，可作整体功能背景；其中「工作区脏、288 个改动未提交」的说法已过期）

---

## 0. 一句话现状

上一轮已把「正文状态栏配色跟随正文 / 全局日夜联动 / 我的页明暗切换按钮」做完并提交（`9d20ecb`，277 个文件）。
**本轮要做的事还没开始写代码**：① 我的页「阅读热力图」与「每日记录」功能重复，需要收敛合并；② 用户另外要求的全项目代码精简。
所有调研结论已在第 4 节，接手者可直接跳到第 5 节实施，不需要重新读代码。

---

## 1. 环境与固定命令（照抄即可）

### 1.1 路径与工具链

| 项目 | 值 |
|---|---|
| 仓库 | `/home/fy/projects/fqapp-src` |
| Flutter | `$HOME/flutter/bin/flutter` |
| JDK | `$HOME/jdk17` |
| Android SDK | `$HOME/Android/Sdk`（build-tools `36.0.0`） |
| adb | `/mnt/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe` |
| 真机 serial | `b2f8e975` |
| APK 中转目录 | `/mnt/d/APP/agent/apk/`（v28 是上一轮产物） |

### 1.2 构建

```bash
cd /home/fy/projects/fqapp-src
export JAVA_HOME=$HOME/jdk17
export PATH=$HOME/flutter/bin:$HOME/jdk17/bin:$PATH
export ANDROID_HOME=$HOME/Android/Sdk
flutter build apk --release
```

### 1.3 校验 APK（签名 / 对齐 / 包信息）

```bash
export JAVA_HOME=$HOME/jdk17
export PATH=$HOME/flutter/bin:$HOME/jdk17/bin:$PATH
python3 scripts/verify_android_apk.py \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --build-tools /home/fy/Android/Sdk/build-tools/36.0.0 \
  --report-dir build/ci-artifacts/verification
```

### 1.4 装到真机（**必须 `require_escalated`**）

```bash
/mnt/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe -s b2f8e975 install -r \
  /home/fy/projects/fqapp-src/build/app/outputs/flutter-apk/app-release.apk

# 版本 / 更新时间
/mnt/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe -s b2f8e975 shell \
  dumpsys package com.fqapp.fqapp | grep -E "versionName|versionCode|lastUpdateTime"

# 截图取证
/mnt/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe -s b2f8e975 exec-out \
  screencap -p > /tmp/shot.png
```

### 1.5 静态检查与测试

```bash
cd /home/fy/projects/fqapp-src
export PATH=$HOME/flutter/bin:$PATH
flutter analyze                       # 上一轮：No issues found
flutter test test/stats_page_test.dart test/stats_page_widget_test.dart \
             test/reading_report_test.dart test/reading_report_page_test.dart \
             test/reading_stats_test.dart test/comprehensive_ui_preferences_test.dart
```

---

## 2. 仓库状态与 git 规则

- `9d20ecb feat: 阅读器/听书/笔记多项体验改造，README 与文档同步` 已提交 **277 个文件**（含 134 个删除项：废弃的短剧 Web 资源 `assets/web/video.html`、`assets/drama/*.webp` 等）。
- 已把历史遗留调试残留写进 `.gitignore`（`$null`、`candidates.txt`、`content-*.json`、`detail-oldman.json`、`dir-oldman.json`、`huozhe_candidates.txt`、`inspect_huozhe.txt`、`probe_books.txt`、`screen-current.png`、`search-book.json`、`search-lorenyuhai.json`、`window.xml`、`window-current.xml`）。**这些文件仍在磁盘上，只是不入库**，不要删用户文件。
- **严禁** `git reset` / `git checkout .` / `git clean` / `git stash`（用户历史存量改动一旦被冲掉无法恢复）。
- 本轮建议**分批 commit**（服务层 / 报告页 / 我的页各一次）；用户明确说过「提交所有代码」，做完要提交。

---

## 3. 本轮需求原文（用户最后几条消息）

### 3.1 主题一：我的界面「热力图 / 每日记录」去重（**主要任务**）

> 我的界面中「阅读热力图」和「每日记录」存在功能重复。改造方向：
> - 点击「阅读热力图」进入详情页；
> - 详情页包含「每日阅读」模块，展示每天阅读时长；
> - 合并或收敛两者的重复逻辑，不要保留两套并行实现。
> 具体交互形态、布局、数据聚合方式由你自行决定。

**授权扩展**：主动扫描整个界面找其他可优化点（重复入口、同一数据多处呈现、绕远交互、分散的阅读数据展示、可复用却重复实现的 UI 片段）。每个优化点说明「位置 / 问题 / 建议 / 风险」；低风险明确项直接改，中高风险先说明。

**协作方式**：建议派 A（explorer 只读梳理热力图+每日记录）、B（explorer 只读梳理阅读时长数据链路 + 扫其他优化点）、C（worker 实现），主线程汇总决策。

### 3.2 主题二：代码精简（独立任务，尚未开始）

> 用 Codex 原生子代理执行代码精简。派生 **2 个 explorer 并行只读扫描**：
> - A：全项目死代码 / 未引用函数类变量导入 / 依赖清单里没人引用的依赖；
> - B：重复逻辑 / 过度抽象 / 单实现接口 / 多层无实质逻辑的转发函数、别名、空壳模块。
> 输出格式：`文件路径、行号范围、精简理由、风险等级（低/中/高）`。
> 两者都返回后才进入阶段二；主线程合并去重、按风险排序、**直接执行不用等确认**；低风险优先，中高风险逐项执行并单独验证；每批跑 lint/test。

**禁止**：子代理改文件、子代理跑 git；不重构与精简无关的代码风格；不改公开 API 签名与语义；可能被动态引用（反射 / 字符串拼接 / 配置驱动加载）的一律标「待确认」不删。

### 3.3 已完成的关联需求（**不要回退**）

> 「系统深色时上方原生状态栏是黑色，切日间很突兀」→ 已修复：
> - `lib/pages/reader_page.dart` 新增 `SystemUiOverlayStyle get _systemOverlayStyle`（底色取 `preset.backgroundColor`，图标明暗取反），`AnnotatedRegion` + `_syncSystemBars()` 切模式后重发样式。
> - `android/app/src/main/kotlin/com/fqapp/fqapp/MainActivity.kt` 的 `onCreate` 新增 `applyStartupThemeColors()`：读 `FlutterSharedPreferences` 的 `flutter.theme_mode`，首帧前设 window 底色（深 `#201F1D` / 浅 `#FAF9F6`）、透明状态栏/导航栏、正确的 `isAppearanceLightStatusBars`。
> - `android/app/src/main/res/values/styles.xml` 与 `values-night/styles.xml` 都加了透明 statusBar / navigationBar 及对应 light 标志。
> - `lib/services/app_theme.dart` 新增 `themeModeIsDark()` 与 `setThemeMode()`；`reader_page.dart` 订阅 `themeModeNotifier` 双向同步；`lib/pages/mine_page.dart` AppBar 设置图标左侧新增明暗切换按钮。
> - 测试：`test/reader_interface_test.dart` 新增「读正文切夜间会带上整个 App，全局切亮色正文跟着回日间」。

---

## 4. 已完成的分析（结论可直接用）

### 4.1 界面结构

「我的」页 = `MinePage`（`lib/pages/mine_page.dart`，289 行）只画头部，正文整体塞给 `StatsPage`：

```dart
// lib/pages/mine_page.dart:78
body: StatsPage(header: _buildProfileHeader(context, scheme, palette)),
```

`MinePage` 头部：书友卡片（80-158）、四个快捷入口 `_buildShortcutTile`（160-215：**笔记 / 章节缓存 / 应用设置 / 关于我们**）、小标题「阅读与视听统计」（217-240）。AppBar 右侧：明暗切换按钮（43-64）+ 设置按钮（65-75）。

`StatsPage`（`lib/pages/stats_page.dart`，1279 行）列表顺序见 `build()`（312-369）：

| # | 卡片 | 行号 | 说明 |
|---|---|---|---|
| 1 | header（MinePage 头部） | 317-320 | |
| 2 | `_dateHeader()` 日期标题 | 322 | 可点选日期，副标题「每日阅读时长持续统计中」 |
| 3 | `_OverviewCard` 六宫格 | 323-330 / 定义 708-799 | 今日 / 本月 / 总计 / 活跃天数 / 累计字数 / 连续打卡 |
| 4 | `_Card('阅读热力图')` | 331-352 | 内含 `_Heatmap`（807-931），16 周格子，`onTap` → `ReadingReportPage` |
| 5 | `_NotesEntryCard` 我的笔记 | 353-360 / 定义 538-618 | 批注数量 + 跳笔记页 |
| 6 | `_RecentBooksCard` 最近阅读 | 361-365 / 定义 933-1059 | 6 条：封面+书名+读到第几章+时长 |
| 7 | `_DailyRecordsCard` **每日记录** | 366-370 / 定义 1061-1120 | 固定回溯 14 天，日期 / 今天·昨天·周几 / 时长 |
| 8 | `_RecentCoversCard` 最近封面 | 371 / 定义 1122-1186 | 5 张封面横滑，**与 #6 同一批数据** |
| 9 | `_RankCard` 阅读排行 | 372 / 定义 1196-1279 | 前 5 名 + 「更多」弹窗 `_showRank`(208) |

### 4.2 重复点判定（核心结论）

**A. 「阅读热力图」与「每日记录」不是简单的两套 UI，而是两套并行的时间聚合：**

- 热力图：`_heatmapCells()`（410-418）用 `readingHeatmapDates(_selected)`（468-477）生成 112 天，再查 `_dayMinutes[_dayKey(date)]`。
- 每日记录：`_DailyRecordsCard`（1061-1120）**自己**在 `build` 里循环 `selected.subtract(Duration(days: i))` 生成 14 天，再查同一个 `_dayMinutes`。
- 详情页 `ReadingReportPage`：又用第三套聚合 `ReadingReport.dayMinutes` + `minutesIn/activeDaysIn/booksIn/topDayIn`（`lib/services/reading_report.dart:243/256/269/285`）+ `barsFor`。

三处口径都来自同一份 `{bookId: {yyyy-M-d: 秒}}` 快照，但**三套代码各自遍历**。合并在语义上完全安全。

**B. 日期/时长格式化各写了一份：**

| 重复项 | stats_page | reading_report.dart |
|---|---|---|
| 日键 | `_dayKey` 465 | `reportDayKey` 29（完全等价） |
| 时长 | `_formatDuring` 511-523 | `formatReadingDuration` 524-532（等价；后者不含「天」单位） |
| 日期 | `_formatDate` 493 / `_formatMonth` 495 | 报告页用 `_periodLabel`（`y年` / `M月`） |

> 差异：`_formatDuring` 对 ≥1440 分钟输出「N天…」，`formatReadingDuration` 只输出「N小时…」。若统一，建议保留 `formatReadingDuration`，只有「总时长」这种可能超 24h 的地方用 `readingDurationParts`（534-547，会自动换「小时」大数字）。两者在 0 分钟时都返回「0分钟」。

**C. 同一批「最近阅读」数据画了两张卡**：#6 `_RecentBooksCard`（6 条，带章节与时长）与 #8 `_RecentCoversCard`（5 张纯封面横滑），数据源都是 `_history`，点击回调都是 `_openHistory`。**#8 是纯冗余**，测试里没有任何断言引用「最近封面」。

**D. 笔记入口出现三次**：MinePage 快捷 tile「笔记」（166-176）、`_NotesEntryCard`（353-360）、报告页 `_MetricGrid` 的 `onNotesTap`（429-437）。三者都 `Navigator.push(NotesPage())`。

### 4.3 数据链路（改之前必须理解）

```
阅读页计时 → LibraryStore.recordReadingSecond()
           → readTimeSnapshot()  {bookId: {yyyy-M-d: 秒}}
           → readTimeListenable 通知

StatsPage._reloadFromStore()  (154-192)
   historySnapshot() / readTimeSnapshot() / readTimeKindSnapshot()
   → 过滤非 book/audio 类型（_statisticsKind / _supportedStatisticsKinds 421-465）
   → _computeDayMinutes() (57-82)：秒/60 累加；无真实数据的旧记录按每本 10 分钟估算（_flatBookMinutes=10，33）
   → _dayMinutes  Map<yyyy-M-d, 分钟>
   → 热力图 / 概览卡 / 每日记录 / 排行 全部读它

ReadingReportPage._load()  (89-143)
   buildBookDayMinutes(history, readTimeSeconds)  (reading_report.dart:132)
   → ReadingReport{ bookDayMinutes, books, notes }
   → dayMinutes = sumDayMinutes(...)  (:160)
   → minutesIn / activeDaysIn / booksIn / topDayIn / barsFor

字数与打卡（独立存储）：
   ReadingStatsStore (lib/services/reading_stats_store.dart)
   SharedPreferences 单键 reading_stats_v1  {yyyy-M-d: 字数}
   → totalChars / currentStreakDays / changes 通知
```

**结论**：`_computeDayMinutes`（stats_page:57-82）与 `buildBookDayMinutes`（reading_report.dart:132）是**同口径的两份实现**，差异仅是后者还按书保留明细。合并时让 stats_page 复用报告层（或反之），不要新增第三份。

### 4.4 扫描出的其他可优化点（含风险）

| # | 位置 | 问题 | 建议改法 | 风险 |
|---|---|---|---|---|
| 1 | stats_page:1061-1120 `_DailyRecordsCard` | 与热力图/报告页重复的日聚合，仅回溯 14 天、无跳转 | **删除**，能力并入报告页「每日阅读」 | 低 |
| 2 | stats_page:525-535 `_daySubtitle` | 仅被 `_DailyRecordsCard` 使用 | 随 #1 一起删（逻辑搬到报告页内部） | 低 |
| 3 | stats_page:1122-1186 `_RecentCoversCard` + 调用点 371 | 与「最近阅读」同数据重复展示，信息量更低 | **删除** | 低 |
| 4 | stats_page:465 `_dayKey` | 与 `reportDayKey` 等价 | 全部替换为 `reportDayKey([...])`，删本地函数 | 低 |
| 5 | stats_page:511-523 `_formatDuring` | 与 `formatReadingDuration` 等价 | 统一到 `formatReadingDuration`；总时长处用 `readingDurationParts` | 低-中（>24h 文案会从「1天2小时」变「26小时」） |
| 6 | stats_page:57-82 `_computeDayMinutes` | 与 `buildBookDayMinutes` 同口径两实现 | 复用报告层 `buildBookDayMinutes` + `sumDayMinutes`（需处理 kind 过滤） | 中 |
| 7 | stats_page:538-618 `_NotesEntryCard` + MinePage 快捷 tile + 报告页 notes 格 | 三个入口去同一页 | 把批注数并入 MinePage 快捷 tile 标签（如「笔记 · 12」），删卡片 | 中（产品取舍，**先问再做**） |
| 8 | stats_page:708-799 `_OverviewCard` vs 报告页 `_SummaryBlock`/`_MetricGrid`/`_WeekStats` | 「今日/本月/总计/活跃天数/连续打卡」与报告页指标重叠 | 概览保留（不同粒度），可把「活跃天数」换成「读完本书数」等不重复指标 | 中（产品取舍） |
| 9 | `_RecentBooksCard._cover`(1020-1058) / `_RecentCoversCard` 内联封面 / `_BookCover`(report:1500) | 三份封面渲染（都走 `PosterCache`） | 抽公共 `BookCoverThumb` 参数化宽高圆角 | 低-中（做完 #3 只剩两份，收益变小） |
| 10 | stats_page:378-408 `_dateHeader` | 可点选日期但其它卡都跟 `_selected` 走，交互不明显 | 加小箭头 / 「今天」回跳 | 低 |

---

## 5. 实施方案（建议顺序，每批独立可验证）

> 原则：**服务层先做（可单测）→ 报告页加模块 → 我的页收口删除**。每批跑 `flutter analyze` + 对应测试，通过后再进下一批。

### Batch 1（低风险，纯服务层）：给 `ReadingReport` 加「按天列表」

`lib/services/reading_report.dart`，`class ReadingReport`（200 行起）新增：

```dart
/// 范围内逐日阅读时长，按日期正序；[includeEmpty] 为 false 时只返回有记录的天。
List<({DateTime day, double minutes})> dailyIn(
  ReportRange range, {
  bool includeEmpty = false,
}) {
  final out = <({DateTime day, double minutes})>[];
  for (var day = range.start;
      !day.isAfter(range.end);
      day = day.add(const Duration(days: 1))) {
    final minutes = dayMinutes[reportDayKey(day)] ?? 0;
    if (!includeEmpty && minutes <= 0) continue;
    out.add((day: day, minutes: minutes));
  }
  return out;
}
```

把「今天 / 昨天 / 周几」标签逻辑也收敛到一处（页面私有 helper 或 service）。

**验证**：`test/reading_report_test.dart` 加用例（空范围、含 0 天、跨月边界）。

### Batch 2：报告页新增「每日阅读」模块

文件 `lib/pages/reading_report_page.dart`。

**插入锚点**：`build()` children 中 `_ChartCard(...)` 结束于 **458 行**，459 是 `const SizedBox(height: 12),`，460 是 `_TopBookCard(`。新模块插到 **459 与 460 之间**（柱状图下方、阅读最久上方）：

```dart
_DailyReadingCard(
  days: report.dailyIn(_range, includeEmpty: _scope == ReportScope.week),
  range: _range,
  scope: _scope,
),
const SizedBox(height: 12),
```

**组件设计建议**：

- 容器与 `_ChartCard` 完全一致（`palette.surface`、圆角 16、`palette.line` 0.6 描边、padding `16,12,12,14`），标题「每日阅读」，右侧小字显示周期合计（`formatReadingDuration(report.minutesIn(_range))`）。
- 每行：左「M月D日 + 今天/昨天/周X」，中一条水平进度条（宽度 = 该天 / 范围内最大值，高 6、圆角 3、色 `palette.accentText`），右 `formatReadingDuration(minutes)`；0 分钟显示 `--`，进度条用 `palette.line`。
- 默认最多 14 行，超出用「展开全部（共 N 天）」；展开状态建议提到 `_ReadingReportPageState`，避免滚动重建丢状态。
- 空态复用 `_EmptyState` 或一行「这段时间还没有阅读记录」。
- 年/总量档天数可能 300+：默认只显示最近 14 个「有记录」的天，展开后全部。
- **`ReportScope.timeline` 走 `_buildTimeline`，不经过这段 children，不要插进 timeline。**

### Batch 3：我的页收口

1. `lib/pages/stats_page.dart`
   - 删 `_DailyRecordsCard`（1061-1120）及调用（366-370）。
   - 删 `_daySubtitle`（525-535）。
   - 删 `_RecentCoversCard`（1122-1186）及调用（371）。
   - 热力图卡 `subtitle`（339 行 `'最近 16 周 · 点击查看详细报告'`）改为 `'最近 16 周 · 点击查看每日阅读'`。
   - 可选：#4 / #5 替换 `_dayKey` / `_formatDuring`（注意 `sumMinutesForMonth` 仍用 `_monthPrefix`，别动）。
2. 确认 `_hasStats`、`_selected`、`_pickDate`、`_heatmapCells` 仍被使用（是）。
3. 跑第 6 节测试。

### Batch 4（可选，产品决策项，先问用户）

笔记入口收敛（#7）、概览卡指标替换（#8）、封面缩略图抽取（#9）。

---

## 6. 测试清单

### 6.1 现有相关测试

| 文件 | 关注点 |
|---|---|
| `test/stats_page_test.dart` | 聚合逻辑（`_computeDayMinutes` 口径、`sumMinutesForMonth`） |
| `test/stats_page_widget_test.dart` | 我的页渲染；**46 行 `expect(find.text('阅读热力图'), findsOneWidget)`**；断言 `ValueKey('reading-heatmap-cell-$i')` 与「周一/周三/周五」标签垂直对齐（布局敏感） |
| `test/reading_report_test.dart` | 报告层纯数据：`minutesIn` / `activeDaysIn` / `booksIn` / `topDayIn` / `milestones` |
| `test/reading_report_page_test.dart` | 报告页渲染与五档切换 |
| `test/reading_stats_test.dart` | `ReadingStatsStore` 字数 / 连续打卡 |
| `test/comprehensive_ui_preferences_test.dart` | **160 行也断言「阅读热力图」**；偏好读失败时不能抛异常 |

> 全仓库 **没有** 测试引用「每日记录」「最近封面」「DailyRecords」，所以 Batch 3 删除安全；**新增**「每日阅读」后建议补 `reading_report_page_test.dart` 用例（周档 `find.text('每日阅读')` 存在、行数 = 7）。

### 6.2 必须跑的回归

```bash
flutter analyze
flutter test test/stats_page_test.dart test/stats_page_widget_test.dart \
             test/reading_report_test.dart test/reading_report_page_test.dart \
             test/reading_stats_test.dart test/comprehensive_ui_preferences_test.dart \
             test/reader_interface_test.dart
```

> 已知历史遗留：`test/reader_system_bars_test.dart` 有 5 条陈旧用例（断言「不请求沉浸模式」、点「收起阅读菜单」），**与本任务无关**，不要为让它过而改产品代码。

---

## 7. 子代理现状与重派模板

已派出 **两轮 explorer**，全部因用户手动打断（`wait_agent` 被 abort）而 `shutdown`，**没有产出**。接手者需重新派。

本 surface 是 **Codex App（outside tmux）**，`omx team` / `omx question` 不可用；用 **Codex 原生 `spawn_agent`**（`agent_type: "explorer"` 只读，`"worker"` 实现），并发上限 6。

### 7.1 代码精简两个扫描子代理（可直接复制）

**子代理 A（死代码/冗余依赖）**

```
只读扫描（严禁修改文件、严禁任何 git 写操作：commit/reset/checkout/add）。
仓库 /home/fy/projects/fqapp-src（Flutter，代码在 lib/，测试 test/，原生 android/ native/ rust/）。
任务：找出未被任何入口引用的私有/顶层函数、类、变量、常量；未使用的 import；
检查 pubspec.yaml 声明但代码零 import 的第三方依赖；android/app 中确凿不再引用的代码（低优先）。
要求：用 rg 交叉验证至少 2 种引用形态；可能被反射/字符串拼接/配置加载动态引用的标「待确认」；
排除 build/ .dart_tool/ release-archives/；仅测试使用的 helper 注明「仅测试使用」。
输出：| 文件:行号 | 对象 | 精简理由 | 风险(低/中/高) |，最多 40 条，宁缺毋滥；末尾 5 行总体结论。不要输出改法。
```

**子代理 B（重复逻辑/过度抽象）**

```
只读扫描（严禁修改文件、严禁任何 git 写操作）。
仓库 /home/fy/projects/fqapp-src。
任务：① 相同/高度相似代码块（可抽共享函数/常量），重点 lib/pages 与 lib/widgets 之间、
多个 *_store.dart / *_cache.dart 之间的重复读写；② 单实现无扩展必要的 interface/abstract/工厂/钩子；
③ 多层无实质逻辑的转发函数、别名、空壳模块。
要求：重复项必须写出两处 文件:行号；纯装饰性相似不报（除非 ≥3 处且 ≥10 行）；不建议引入新依赖。
输出：| 涉及位置 | 问题 | 建议改法 | 风险 |，最多 30 条；末尾 5 行结论（哪些可直接做、哪些别动）。
```

### 7.2 本轮界面优化三个子代理

- **A（explorer）**：热力图/每日记录的实现、数据来源、路由、组件结构、重复点 —— **第 4 节已是答案，通常不必重派**。
- **B（explorer）**：阅读时长数据链路 + 其他可优化点 —— **4.3 / 4.4 已覆盖**。
- **C（worker）**：按第 5 节 Batch 1-3 实现。允许改：`lib/services/reading_report.dart`、`lib/pages/reading_report_page.dart`、`lib/pages/stats_page.dart`、`test/reading_report_test.dart`、`test/reading_report_page_test.dart`。提示词必须包含：**不要 commit、不要动其它文件、不要改公开 API 签名、保留 9d20ecb 已完成的日夜/状态栏逻辑**。

### 7.3 已结束的子代理 ID（已 shutdown，无需清理）

`01a166f3-395f-79a3-a20f-a597cf59142b`、`01a166f3-3abd-7051-b1b7-7a12a626da6f`、`01a166f3-3bf3-7ba3-8207-f028f013c4c9`、`01a166f3-3d30-7870-a885-f3cc05288ed8`、`01a16733-13c1-7462-818b-8e341416f730`、`01a16733-1511-7a30-a32f-33a6128714c9`、`01a16733-1669-7281-936f-bb0d48828e87`。

---

## 8. 真机验证清单（用户要求人工核验）

1. 构建 → `verify_android_apk.py` → `install -r`。
2. 打开「我的」：
   - [ ] 不再出现「每日记录」卡；
   - [ ] 不再出现「最近封面」卡（若采纳 #3）；
   - [ ] 「阅读热力图」卡副标题为「最近 16 周 · 点击查看每日阅读」。
3. 点「阅读热力图」进「我的阅读」：
   - [ ] 周档可见「每日阅读」，7 行；
   - [ ] 有阅读的天显示时长与进度条，没读的天显示 `--`；
   - [ ] 月/年/总：行数随周期变化，超过 14 行有「展开全部」；
   - [ ] 切「阅历」档时不出现「每日阅读」；
   - [ ] 滚动顺畅，卡片间距与既有 12px 一致。
4. 深色模式下重复 2-3：底色/文字/进度条跟随主题，无黑边、无白块。
5. 返回「我的」下拉刷新，数据不闪、不重复计算。

---

## 9. 禁忌清单

- 不 `git reset` / `checkout` / `clean` / `stash`；不 force push；不删用户磁盘上的调试文件（已 gitignore）。
- 不删可能被动态引用的代码（反射、`toString()` 拼类名、assets 配置驱动、`MethodChannel` 名、路由名常量），遇此标「待确认」。
- 不改公开 API 签名/语义（尤其 `ReadingReport` 已有成员、`StatsPage({header})`、`MinePage`）。
- 不引入新 UI 库；沿用 `HomePalette` / `flutter_lucide` / `CachedNetworkImage(PosterCache)`。
- 不重构与本次无关的代码风格；不顺手格式化整文件（CRLF 文件换行符不要整体改掉）。
- 不动阅读器/听书核心逻辑（`reader_page.dart`、`listen_*`）与 9d20ecb 的状态栏/日夜改动。
- 子代理不得 commit，也不得修改不属于其 write 集合的文件。

---

## 10. 完成定义（DoD）

1. 「每日记录」「最近封面」从我的页移除，无孤立符号（`_DailyRecordsCard` / `_daySubtitle` / `_RecentCoversCard` 不再被引用）。
2. 报告页「每日阅读」可用，五档行为明确，空态与深色模式正确。
3. 日聚合只剩两处实现（`_computeDayMinutes` 供我的页概览；`buildBookDayMinutes` + `dailyIn` 供详情页），且 `dailyIn` 有单测；不再有三处并行循环。
4. `flutter analyze` 无 issue；6.2 节测试全绿。
5. 代码精简：两份清单合并去重后执行，每批单独验证并报告；「待确认」项保留并显式列出。
6. 产物：APK 构建 + 校验通过 + 真机安装，报告 SHA-256、字节数、`lastUpdateTime`。
7. 全部改动已 commit（可拆 2-4 个），工作区干净。
8. 更新 `QINGQIE-CHANGES.md` 与 `AGENT-HANDOVER.md`（记版本号、摘要、遗留项）。
