# OPTIMIZATION-REPORT.md — refactor/slim-optimize 分支验收报告

> 分支：`refactor/slim-optimize`（基线 `8a3bcaa`，即 master 上 v41–v55 累积提交）
> 护栏：`OPTIMIZATION-GUARDRAILS.md`（本分支根目录，逐波自查通过，零冲突项）

---

## 0. 最终验收数字

| 项 | 基线 | 最终 | 结论 |
| --- | --- | --- | --- |
| flutter analyze | 0 error / 0 warning / 0 info | **0 / 0 / 0** | ✅ 无新增（在 ASCII 路径构建副本执行，中文路径下 analysis server 会崩溃） |
| flutter test 全量 | 1511 通过 / 10 跳过 / 0 失败 | **1511 / 10 / 0** | ✅ 全绿，零断言修改 |
| 直接依赖数 | 19 | **18**（移除 flutter_riverpod） | ✅ |
| git diff --stat | — | 13 文件，+316 / −226 | 见下方分波明细 |

分支提交（`git log --oneline`，新→旧）：

```
da62b2a refactor(2C): reader_page 拆出目录抽屉组件 ChapterDirectorySheet
08f8bc1 refactor(2B): 分类兜底渐变收敛为 CuratedCategory.defaultGradient
b1e51c4 refactor(2A): 空catch补日志 + 移除未使用的 flutter_riverpod
```

---

## 1. 第 0 步事实基线（摘要）

- **lib/ TOP5 大文件**：reader_page 4801 / notes_page 2086 / reading_report_page 1925 / audio_page 1867 / api_client 1650（完整 TOP20 见本节附表¹）。rust/ 大文件（manga.rs 3162、video.rs 2613 等）全部位于禁改区（护栏 §2）。
- **重复模式**：`showDialog` 直接调用 **0 处**（Dialog 类已由 `showAppDialog` 收敛）；`showModalBottomSheet` 24 处（10 文件，形态异构）；颜色字面量 `0xFF2FA98C` 8 处 / `0xFF176B58` 2 处 / `0xFF5E6B64` 1 处；"setState+异步加载"模式约 30 处。
- **危险信号**：TODO / FIXME / @Deprecated / `print(` / `// ignore:` 全部为 **0**；空 `catch (_) {}` 9 处；`catch (_)` 共 163 处（其余带处理体）。
- **依赖候选（引用 ≤2 文件）**：flutter_riverpod(1)、flutter_secure_storage(1)、flutter_cache_manager(1)、connectivity_plus(1)、image(1)、flutter_svg(1)、archive(1)、xml(1)、url_launcher(2)、hive_ce_flutter(2)。

¹ TOP20：reader_page 4801、notes_page 2086、reading_report_page 1925、audio_page 1867、api_client 1650、library_page 1615、reader_chapter_layout 1547、media_item 1401、audio_playback_controller 1397、detail_page 1316、library_store 1167、audio_sections 1147、reader_appearance_sheet 1132、reader_note_block 1072、stats_page 1062、imported_book_store 1059、search_page 1033、bookshelf_card 1015、reader_paged_view 1008、home_page 945。

## 2. 第 2A 波：零行为变更清理

- **死代码**：全库 private 类/函数/顶层定义引用计数扫描 → 零引用项 **0 个**，无可删项（uses=2 的均为"定义+1 次调用"的正常方法或 State 类）。
- **空 catch**：9 处中 8 处补 `AppLog.w(tag, msg, error: error)`（书架删书、搜索历史读/清、阅读器缓存标记、Rust 日志写/清、TTS stop/shutdown）；`app_log.dart:166` **1 处保留**——日志系统自身 detach，补日志会递归。
- **print / // ignore: / TODO**：基线即为 0，无操作。
- **依赖瘦身**：移除 **flutter_riverpod**——lib/ 仅 main.dart 用 `ProviderScope` 包裹（其注释所称 ConsumerWidget 已不存在），test/widget_test.dart 同步处理并修正过时注释；pub get / analyze / 全量测试三环节全绿后落地。其余 9 个 ≤2 引用候选**全部保留**：flutter_secure_storage（Keystore 红线）、flutter_cache_manager（PosterCache 必需）、hive_ce_flutter（Hive.initFlutter）、connectivity_plus / image / flutter_svg / archive / xml / url_launcher（各自唯一承载联网检测、长图导出、SVG 封面、备份导入、本地书解析、外部跳转功能，移除即功能回退，违反零行为变更）。
- 回滚项：无。

## 3. 第 2B 波：重复收敛

- **颜色**：3 处完全相同的默认渐变 `[0xFF2FA98C, 0xFF1F7F69]`（curated_book.dart fromMap、curated_book_page、curated_book_cover）收敛为模型层 `CuratedCategory.defaultGradient` 共享常量；色值不变，视觉输出逐字节一致。`0xFF176B58` 2 处与 `0xFF5E6B64` 1 处均为单一语义使用（进度角标对比度渐变 / 主题 muted 注释锚点），**不构成重复，保留**。
- **对话框/弹窗**：showDialog 为 0（已收敛态）。24 处 showModalBottomSheet **评估后不收敛**：各处绑定领域主题色（阅读 preset.panelColor / 详情 canvas / 批注奶油色 / TTS surface）、形状（18/22/24/28 圆角）与动画参数（eink 瞬时、180/300/320ms 各异），强行统一必然改变视觉输出，与护栏 §3/§6 冲突。
- **异步骨架**：30 处 setState+异步模式**评估后跳过**：各页状态机字段（_loading/_refreshing/_error/_hasMore 等）与流转细节互不相同且被现有 1511 个测试锁定；为统一而新建 AsyncState<T> 需重写 30 处状态机，风险收益比不成立（护栏兜底规则第 4 条）。
- 回滚项：无。

## 4. 第 2C 波：文件拆分

- **reader_page.dart：已拆**（4801 → 4598）。`_ChapterDirectorySheet`（目录抽屉，含 State，249 行）独立为 `lib/widgets/reader/chapter_directory_sheet.dart`，public 化为 `ChapterDirectorySheet`（补 `super.key`），构造参数与行为不变；拆分时误带入的 `_ScrollSegment`（滚动窗口段，属页面主逻辑）已移回原文件——该失误由 analyze 当轮捕获并修复，最终 0 问题。
- **notes_page.dart：评估后不拆**。行组件（_TimelineNoteRow/_MarkRow 等）依赖页面文件内的顶层 private 函数（_sameDay/_dayLabel/_timestampLabel）与 State 回调，拆分需连带 public 化工具函数，改动面大。
- **reading_report_page.dart：评估后不拆**。18 个私有展示组件仅本页使用，拆出需全部 public 化（18 处改名 + 逐个补 key），与"最小改动"兜底规则冲突；组件间共享 ReportScope 等页面层类型，耦合紧。
- **audio_page.dart：评估后不拆**。_AudioCommentsSheet/_AudioCatalog 与播放控制器回调（代数过滤、会话生命周期）强耦合。
- **library_page.dart：评估后不拆**。chip/tab 小组件依赖页面 palette 上下文与编辑态回调，单类均 <80 行，拆分收益趋零。
- 回滚项：无。

## 5. 依赖增减

- 移除：flutter_riverpod（详见 2A）。
- 新增：无。
- pubspec.lock 随之收缩（riverpod 及其传递依赖 native_stack_traces 等退出解析树）。

## 6. 回滚说明

- **整体放弃本分支**：`git checkout master && git branch -D refactor/slim-optimize`（若已合并则 `git revert <merge-sha>`）。
- **单独回滚某一波**（按提交粒度）：
  - 2A：`git revert b1e51c4`
  - 2B：`git revert 08f8bc1`
  - 2C：`git revert da62b2a`
- 每波为独立提交且互不重叠文件冲突最小化（2A 触 backend/system_tts/library/search/reader；2B 触 curated 三件；2C 触 reader_page + 新文件），revert 任意一波不影响其余两波。

---

## 附：验证环境说明

- 静态分析与测试在 ASCII 路径构建副本（`E:\fqapp-build2`，与仓库 `//MIR` 同步）执行：仓库所在中文路径会使 Dart analysis server 崩溃（`FormatException`，交接文档已记录）。
- 真机验收：**未做**（本任务为纯代码重构，行为零变更已由 analyze + 1511 个测试背书；按 AGENTS.md 要求如实标注）。
