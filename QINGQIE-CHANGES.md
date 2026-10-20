# 青茄阅读改造说明（基于 fqapp）

本仓库是 [fqapp](https://github.com/ch6vip/fqapp) 的**功能增删分支**，不是重写：
在保留原有「番茄系上游 API + Rust 进程内核心 + Flutter UI」架构的前提下，
按「面向青少年的纯净阅读器」定位删掉非阅读内容，补齐阅读侧的深度功能。

- 上游项目：https://github.com/ch6vip/fqapp （GNU GPL v3）
- 本分支：https://github.com/fangyuzhang/fqapp-qingqie
- 协议：沿用 **GPL-3.0**（见 `LICENSE`，未改动上游版权与署名）
- 代码标注约定：新增/修改处以 `【青茄重构·新增】`、`【青茄重构·删除】`、
  `【青茄重构】` 注释标出，便于审查归属

> **免责声明**：本项目仅用于个人学习与研究，不提供、不分发任何内容，
> 不绕过任何付费/版权机制。请勿用于任何侵犯版权的用途。

---

## 一、删除的功能（短剧 / 漫剧 / 漫画）

产品定位为「只看书」，与短剧/漫剧/漫画相关的**入口**全部移除；
底层 API 与 Rust 核心保持不动（小说正文解密仍依赖同一套签名链路）。

| 位置 | 改动 | 文件 |
|---|---|---|
| 首页分类条 | 6 类 → 3 类（推荐 / 小说 / 听书） | `lib/widgets/home/home_tab_bar.dart` |
| 首页文案 | 去掉「好戏开场」「每一格都藏着一个新世界」等剧集/漫画文案 | `lib/pages/home_page.dart` |
| 首页推荐流 | 过滤 `video / manju / manga` 三类条目 | `lib/pages/home_page.dart` |
| 底部导航 | 4 tab → 3 tab（首页 / 书架 / 我的），移除「短剧」 | `lib/main.dart` |
| 搜索分类 | 6 类 → 3 类（综合 / 小说 / 听书）；综合结果过滤三类 | `lib/pages/search_page.dart` |
| 书架 + 浏览历史 | 不再展示 `video / manju / manga` 条目（数据保留在本地，不删库） | `lib/pages/library_page.dart` |
| 首页 feed 索引 | `HomeNotifier.tabs` 前三项与 UI 分类对齐（全部 / 小说 / 听书），后四项保留给已无入口的 DramaPage 与既有测试 | `lib/pages/home_provider.dart` |

**没有做的事**：没有删除 `drama_page.dart` / `player_page.dart` / `comic_reader_page.dart`
等文件，也没有动 Rust 侧。它们已无主导航入口，保留可让二期随时恢复，
同时避免大范围改动引发回归。

## 二、新增的功能

### 1. 蜗牛读书式批注（核心）

| 能力 | 实现 |
|---|---|
| 长按选句 → 菜单多出「批注」「书摘」 | `lib/widgets/reader/reader_paragraph_menu.dart` |
| 写想法面板（顶部展示原文、下方输入） | `ReaderNoteBlock.showAnnotationEditor` |
| 选中文字画 **2px 红色下划线** | `lib/widgets/reader/reader_text_selection.dart`（`annotationRanges`） |
| 段落下方插入**行内批注块**（米色底 + 红色「批」角标，书摘为「摘」） | `lib/widgets/reader/reader_note_block.dart` |
| 批注块折叠 / 删除 | 同上（点文字折叠，右上角图标折叠、删除带确认） |
| 本地持久化 | `lib/services/reader_annotation_store.dart`（Hive 加密盒 `reader_annotations_v1`，上限 5000 条，写入串行化） |
| 笔记页汇总 + 点卡片回原文 | `lib/pages/notes_page.dart` + `ReaderPage.startTextOffset` |
| 我的页 / 统计页入口 | `lib/pages/mine_page.dart`、`lib/pages/stats_page.dart` |

**排版关键设计**：批注块在排版层是一个「单行、整块高度」的合成块
（`ReaderInlineNote` + `_measureInlineNote`）——分页时整块落页、放不下就整块
推到下一页、绝不从中间切断；滚动模式沿用同一高度。因此**分页与滚动两种模式
共用一套批注排版**，不需要维护两套逻辑。

### 2. 书架分组（在读 / 想读 / 读完）

- `ShelfRecord` 新增 `status` 字段，老记录缺字段按「在读」兜底（`ShelfStatus.normalize`），
  schema 升级不会丢书：`lib/services/shelf_store.dart`
- 书架顶部新增分组 chip（带各组数量），多选后可「移到分组」：`lib/pages/library_page.dart`

### 3. 护眼提醒

连续阅读 45 分钟弹窗提醒休息，可选「休息一下 / 再看 15 分钟 / 今天不再提醒」；
只在阅读器仍是当前路由时弹出：`lib/pages/reader_page.dart`。

### 4. 内容分级（12+ / 15+）

按上游分类与简介关键词判定（悬疑/犯罪/惊悚/战争等 → 15+，其余 12+），
**只做提示、不做硬过滤**，阅读器顶栏显示标签：`lib/services/content_rating.dart`、
`lib/widgets/content_rating_chip.dart`。

### 5. 阅读统计（字数 / 打卡 / 批注数）

- 沿用上游自带的 16 周热力图与阅读时长统计
- **新增按天字数计数器**：`lib/services/reading_stats_store.dart`（SharedPreferences
  单键 JSON，内存累加 + 2 秒防抖落盘），阅读器按章计一次正文字符数
- 概览卡从 4 项扩到 6 项：今日 / 本月 / 总计时长、活跃天数、**累计字数**（万字档位）、
  **连续打卡**（今天没读时自动从昨天起算）
- 新增「我的笔记」卡片显示批注/书摘总数并可进入笔记页

> 字数按「本章排版后的正文字符数」估算，一章计一次，用于展示量级，不做逐字精确统计。

### 6. 批注导出长图

笔记页右上角「导出长图」：`lib/services/note_card_exporter.dart` 用
`PictureRecorder` 直接绘制 1080 宽 PNG（两趟排版：先量后画），
输出到应用文档目录 `qingqie/exports/notes_<时间戳>.png` 并在 SnackBar 提示路径。
不引入图片处理依赖，也不需要分享插件。

## 三、测试

```bash
flutter analyze          # 0 error（仅上游遗留的 1 条 warning）
flutter test             # 1954 passed / 10 skipped
```

新增测试：

- `test/reader_annotation_test.dart`（5 项）：批注块插入位置、不污染正文坐标、
  分页整块不切断、渲染与折叠、坏数据拒绝
- `test/qingqie_reader_features_test.dart`（10 项）：分级判定、书架分组、
  笔记页空态、分级标签渲染、批注字段回读

因删除短剧而同步更新的上游测试（改的是测试数据与结构假设，不是放宽断言）：
`home_page_test`、`search_page_test`、`search_id_page_test`、`home_provider_test`、
`drama_page_test`、`kept_alive_pages_test`、`stats_page_widget_test`。

## 四、本地构建环境（已按国内镜像配置）

本机实测可用的工具链（全部走国内镜像，比官方源快一个数量级）：

| 组件 | 版本 / 来源 | 说明 |
|---|---|---|
| Rust | 1.99.1 `stable-x86_64-pc-windows-gnu` | `RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static` |
| crates 索引 | USTC sparse 镜像 | `~/.cargo/config.toml` 内 `[source.crates-io] replace-with = 'ustc'` |
| 宿主链接器 | WinLibs MinGW-w64 16.2.0 (UCRT) | 本机无 MSVC，改用 GNU 宿主工具链；`winget install BrechtSanders.WinLibs.POSIX.UCRT` |
| Android 目标 | `aarch64-linux-android` | `rustup target add aarch64-linux-android` |
| NDK | 28.2.13676358（脚本硬校验） | `ANDROID_NDK_HOME` 指向该版本 |
| Flutter | 3.47.7 stable | pub 依赖正常解析 |

构建步骤（PowerShell，命令片段）：

1. 原生核心（仓库已带生成的绑定，`-SkipCodegen` 更快）：
   - PATH 追加 `%USERPROFILE%\.cargo\bin` 与 MinGW 的 `mingw64\bin`
   - `ANDROID_NDK_HOME` 指向 `...\ndk\28.2.13676358`
   - 执行 `scripts\build_rust_backend.ps1 -SkipCodegen`
2. 打包 APK：`flutter build apk --debug --target-platform android-arm64`

### 镜像加速的额外处理（都不改仓库文件）

| 卡点 | 处理 |
|---|---|
| Gradle 发行包下载被代理掐断 | 从华为云镜像 `https://repo.huaweicloud.com/gradle/gradle-9.1.0-all.zip` 直接预置到 `~/.gradle/wrapper/dists/gradle-9.1.0-all/<md5(url) 的 36 进制>/` |
| AGP / Kotlin / 三方依赖慢 | `~/.gradle/init.d/mirrors.gradle` 把阿里云 Maven（google / public / gradle-plugin）前置 |
| Gradle JVM 不读 http_proxy | `~/.gradle/gradle.properties` 里 `systemProp.http(s).proxyPort` 跟随 VPN 当前端口（本机实测会变：58503 → 53482 → 51981） |
| Rust 工具链与 crates | `RUSTUP_DIST_SERVER` 指 USTC，`~/.cargo/config.toml` 用 USTC sparse 索引 |
| Flutter 资源 | `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` 走 `flutter-io.cn` |

### 构建验证结果（本机实测）

| 项 | 结果 |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **1961 passed / 10 skipped** |
| Rust 交叉编译 | 成功，`libfqapi_core.so` 6.4 MB（release profile，2m03s） |
| Debug APK | 构建成功，**118 MB**（arm64-v8a，含 `libfqapi_core.so` 与 `libshortplay_crypto.so`） |
| Release APK | 构建成功，**31.7 MB**（R8 混淆 + 资源压缩，字体 tree-shake 96%），未配 keystore 时回落 debug 签名 |

## 五、二期候选（未实现）

1. **批注块拖动排序**：批注与段落是字符偏移绑定，拖动需要额外的锚点模型。
2. **长图接系统分享**：当前只落盘到应用目录，接入分享需新增 share 插件。
3. **书源 / 本地书接入**：本分支沿用上游在线能力，TXT/EPUB 本地导入在另一条线
   （`qingqie-reader` 项目）里实现。

---

# 六、v3：UI 重构为「青少年书房」

## 6.1 视觉系统

| 项 | 旧（番茄橙） | 新（青茄绿） |
|---|---|---|
| 主色 | `#EF5038` 番茄红 | `#2FA98C` 青茄绿（strong `#1F8A72`/dark `#4FC3A4`） |
| 点缀 | 无 | `#E2603F` 珊瑚橙（15+ 标记、重点） |
| 浅色底 | `#FCFAF7` 暖白 | `#FAFBF6` 带绿调的奶油白 |
| 深色底 | `#151517` | `#0F1413` 墨绿黑 |
| 中性色 | 暖灰 | 绿灰（line `#E3E9E1` / muted `#6C7A73`） |

改法：只改 `app_theme.dart` 的 token 与 `HomePalette` 常量（90+ 处引用随之统一），
不逐个页面硬改，避免样式漂移。所有改动集中在两个文件，暗色/墨水屏分支照旧。

## 6.2 首页：编辑部书单（不再推网文）

- 新增 `assets/config/curated_books.json`：**42 本**精选，7 个类型各 6 本
  （古典名著 / 世界文学 / 历史人文 / 科普百科 / 科幻想象 / 成长青春 / 诗歌散文），
  每本带一句话荐语、题材标签、12+/15+ 适龄标记
- 新增 `lib/models/curated_book.dart`（模型 + 加载缓存 + 每日轮换）
- `lib/pages/home_page.dart` **整页重写**：问候头 + 今日荐读大卡 + 分类 chips +
  分类横滑书单 / 分类竖排列表 + 书单说明
- 新增 `lib/pages/curated_book_page.dart`：书目详情（渐变头图 + 荐语 + 「怎么读这本书」+ 同类推荐）
- 新增 `lib/widgets/curated/curated_book_cover.dart`：**文字封面**（分类渐变 + 书名排版），
  不依赖网络封面图，离线也稳定
- **搜索能力完整保留**：详情页底部「在书城搜索《书名》」直接带关键词进搜索页；
  首页右上角也有搜索入口。旧的上游网文流（homeProvider feed）不再被首页调用

「今日荐读」按 `天数 % 书目数` 稳定轮换：同一天固定同一本，跨天自动换。

## 6.3 底部导航：新增「笔记」

`首页 / 书架 / **笔记** / 我的` 四栏。笔记是批注能力的主入口：
点任意一条 → 回到原文对应位置（`ReaderPage.startTextOffset`）。

## 6.4 移除不适合青少年的内容与功能

| 项 | 处理 |
|---|---|
| 短剧 / 漫剧 / 漫画 | v2 已删入口；本次再删「我的 → 剧集缓存」入口 |
| 上游网文推荐流 | 首页不再调用 `homeProvider`，无用户主动搜索就不会推网文 |
| 榜单（RankPage） | 首页入口移除（榜单数据来自上游网文首页响应） |
| 段评 / 书评 UGC | **阅读器段评默认关闭**（`ReaderPreferences.showParagraphBubbles` 默认 false），用户需要时可在排版面板打开 |

## 6.5 测试

- `flutter analyze`：**No issues found**
- `flutter test`：**1961 passed / 10 skipped**
- 新增 `test/home_page_test.dart`（9 项）：今日荐读/分类过滤/进详情/跳搜索/窄屏大字号不溢出/书单数据不变量
- 删除过时用例：`home_scroll_cost_test.dart`（测已移除的网格实现）、
  `comprehensive_ui_loading_test.dart` 的 U04（测已移除的首页分页）
- 受影响的段评用例改为显式开启 `reader_show_paragraph_bubbles`（反映新的真实默认值）

---

# 七、v4 批次：稳定性 / 性能 / 体验修复（提交 ffd9b68）

> 基线：`flutter analyze` 无问题；`flutter test` 2053 passed / 10 skipped；
> release APK 31.8MB，已装真机（Redmi K20 Pro，versionName 1.0.121+126）验证启动正常。

## 7.1 崩溃与卡顿修复（批注链路）

- **FocusNode disposed 崩溃**：`showModalBottomSheet` 的 Future 在 pop 开始时即完成，
  原实现用 whenComplete 释放 controller/focus，退场动画内 TextField 仍 rebuild 触发崩溃。
  重构为 `_AnnotationEditorSheet` StatefulWidget，controller/focus 归 State 持有、dispose 释放
- **批注块高度爆炸**：`_measureInlineNote` 行数无上限 + 宽度下限 40px，
  2000 字批注在窄屏量出 14022px 高。修：maxLines=8、bodyWidth≥120、高度三重夹值、TextPainter dispose
- **键盘两段式卡顿**：键盘升起时 viewInsets 与 padding 同时变化导致整章重分页。
  修：`resizeToAvoidBottomInset: false` + 顶层 MediaQuery 冻结两值；弹层首帧即聚焦
- **批注输入看不清**：输入框/光标/提示/按钮钉死深色，不继承主题
- **进正文卡顿**：新增路由转场门控 `_watchRouteIntro`，动画完成后才放正文

## 7.2 我的阅读报告页（对齐蜗牛读书统计页）

- 我的页热力图卡片整卡可点进 `ReadingReportPage`：周/月/年/总/阅历五档、
  自绘柱状图（可点柱）、四宫格指标、挑战卡、阅读最久卡、阅历时间线
- 新增 `lib/services/reading_report.dart`（纯数据层）、
  `lib/pages/reading_report_page.dart`、`lib/services/reading_report_exporter.dart`（1080 宽 PNG 分享图）
- 无社交能力，用本地打卡/挑战替代朋友排名/会员卡

## 7.3 精选书单直达阅读 + 真实封面

- 新增 `lib/services/curated_resolver.dart`：搜索式解析器（SharedPreferences 缓存 7 天、
  inflight 去重、标题归一化匹配、preferAudio 分支须在 books.isEmpty 兜底之前）
- 点封面直达阅读（DetailPage autoOpenReader）；封面走书城同 CDN，文字封面兜底
- 听书分类：19 本书加 `"audio": true`，kind=audio 自动进 AudioPage

## 7.4 阅读器体验

- **跨章无缝滚动**：`_ScrollSegment` 段窗口（append-only + 视口中心静默换章 + 停稳裁头补偿）；
  删除章末「上一章/下一章/本章评论」三按钮
- **长按按句选中**：`sentenceRangeInText`（句读口径与 TTS 一致）
- **状态栏常显**：`_syncSystemBars` 恒 setImmersive(false)，进出正文不再跳动
- 已知限制：跨章长按选区有意未做（几何表按块下标建键会撞章，属独立需求）

## 7.5 首页与导航

- 删问候语；分类条 + 搜索改固定顶栏；上滑 >160px 浮现搜索按钮；分类功能按钮宫格
- 底部导航：悬浮毛玻璃胶囊 → 整宽实色固定条（extendBody: false）

## 7.6 启动 / 搜索提速

- 删 RootShell 整页「正在启动本地服务」门（后端失败改 SnackBar+重试）
- main() 里 runApp 后立即并行启动 Rust 后端；关键三件并行初始化、可选存储推迟到首帧后
- `ApiClient._get` 加「后端启动中则等待」门；`_deploy` 资源拷贝并行化

## 7.7 构建与体积

- 440MB 安装体积根因 = 装 debug 包；release 仅 31.8MB（R8 + 字体 tree-shake）
- 删未用 cupertino_icons；release 无正式签名时回退 debug 签名；新增 `tool/build_release.ps1`
