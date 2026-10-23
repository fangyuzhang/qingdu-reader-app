# 青茄阅读改造说明（基于 fqapp）

本仓库是 [fqapp](https://github.com/ch6vip/fqapp) 的**功能增删分支**，不是重写：
在保留原有「番茄系上游 API + Rust 进程内核心 + Flutter UI」架构的前提下，
按「面向青少年的纯净阅读器」定位删掉非阅读内容，补齐阅读侧的深度功能。

- 上游项目：https://github.com/ch6vip/fqapp （GNU GPL v3）
- 本分支：https://github.com/fangyuzhang/qingqie-reader-app （**私有仓库**）
  - 历史仓库 `fangyuzhang/fqapp-qingqie`、`fangyuzhang/qingqie-reader` 已停止更新，仅作存档，不要往那里推
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
| 底部导航 | 保留首页 / 书架 / 笔记 / 我的，移除「短剧」；笔记是批注能力的主入口 | `lib/main.dart` |
| 搜索分类 | 6 类 → 3 类（综合 / 小说 / 听书）；综合结果过滤三类 | `lib/pages/search_page.dart` |
| 书架 + 浏览历史 | 不再展示 `video / manju / manga` 条目（数据保留在本地，不删库） | `lib/pages/library_page.dart` |
| 首页 feed 索引 | v5 已删除上游推荐流、旧 HomeNotifier 缓存与短剧 feed；首页只展示本地精选书单 | `lib/pages/home_page.dart`、`assets/config/curated_books.json` |

v5 已进一步删除短剧、漫剧、漫画的客户端页面、组件、下载器、播放器和对应资源；Rust 底层签名/解密链路仍保留，仅服务于小说正文与加密听书，不再提供视频/漫画用户入口。

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

- 440MB 安装体积根因 = 装 debug 包；release 约 31MB（R8 + 字体 tree-shake）
- 删未用 cupertino_icons；release 必须使用正式签名，缺少签名材料时构建失败，禁止回退 debug 签名；新增并强化 `tool/build_release.ps1`

---

# 八、v5 批次：产品范围收口与发布验证

- 版本：1.0.122+127；正式签名 release APK，包名 com.fqapp.fqapp，仅 arm64-v8a。
- 用户入口只保留小说与听书；短剧/漫剧/漫画页面、组件、下载与播放链路、Web 页面和资源已删除。
- 修复搜索分类过滤的真实逻辑错误：首屏与分页都只接受 book、audio，不再让视频/漫画结果混入综合搜索。
- 听书关联作品只保留原著小说；加密听书仍使用 CENC/Media3，不误删 libshortplay_crypto.so。
- 关于页品牌与版本同步；补齐分享桥接服务，清理失效依赖、资源配置和调试文件。
- 签名改为强校验：正式 keystore 缺失时直接失败；新增项目内 Gradle 缓存与 release 构建参数支持。
- 发布脚本改为自动探测 Flutter、Android SDK、JDK 与 Build-Tools，新增 `-ValidateOnly` 前置检查，移除了开源构建流程中的本机固定路径和失效文档链接。
- 验证：flutter analyze 无问题；Flutter 全量 1421 passed / 1 skipped；Web 32 passed；Rust host 9 passed；Android JVM 55 passed；发布脚本前置检查通过；APK 归档到 release-archives/v5/（不改动 v4）。
- 已知限制：跨章长按选区仍是独立后续需求；FFmpeg CENC 集成测试需要本机安装 ffmpeg；Windows 真实 JNI 有 2 条按设计跳过。

# 九、v5.1 批次：正式包启动失败修复与真机覆盖安装

- 版本：`1.0.123+128`，About 页已同步。
- 根因：release 包经 R8/ProGuard 混淆后，`shared_preferences` 的 Pigeon JNI 找不到被改名的 `kotlin.coroutines.Continuation` 等运行类型；不是设备空间不足，也不是本地数据库损坏。
- 修复：在 `android/app/proguard-rules.pro` 保留 Flutter 插件、`kotlin.coroutines`、`kotlin.Result` 和 `kotlin.Unit`，确保 JNI 方法描述符中的类型名不被混淆。
- 启动错误页：`AppBootstrap` 记录真实异常到应用日志，提示改为“本地数据未被清除”，不再诱导用户清理空间或数据。
- 测试稳定性：修复 `AppLog.resetForTest()` 在测试异步环境变化后等待旧写入链导致的挂起。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1421 passed / 1 skipped；APK 签名、版本、ABI、原生库和 16 KiB 对齐检查全部通过。
- 真机：Redmi K20 Pro（`b2f8e975`）已覆盖安装 1.0.123 (128)，首次安装时间未变化，未卸载、未清除数据；进程和 Flutter 引擎正常，关键异常日志为空。
- 归档：`release-archives/v5.1/`，APK SHA-256 `159a29d082c9315bcd3307714c956de9f50d7922782007c8710aa4bdada8779b`。
- 剩余人工确认：安装时手机停在系统 PIN 锁屏，未绕过锁屏；解锁后请检查书架、笔记和阅读进度。

# 十、v8 批次：目录占位章节导致正文为空修复

- 版本：`1.0.125+130`，About 页已同步。
- 根因：部分书源把书名或卷名单独暴露为章节。《老人与海》目录项“老人与海”的接口正文仅有标题 4 个字，真实正文位于下一章，原阅读器据此显示“正文为空”。
- 修复：阅读器允许标题占位章节进入缓存，识别去掉标题后无正文的章节，并自动向后扫描最多 8 个占位章节；扫描成功后同步目录索引，滚动预取同样跳过占位章节。
- 回归：`flutter analyze --no-pub` 无问题；chapter/reader 相关 47 项通过；连续滚动、阅读器界面与分页相关 29 项通过、1 项跳过；新增占位章节跳转真实正文测试。
- 真机：Redmi K20 Pro（b2f8e975）覆盖安装，未卸载、未清数据；《老人与海》占位章节成功显示真实正文并连续翻入下一章；抽查《小王子》《傲慢与偏见》《活着》正文正常，全程未出现“正文为空”。
- APK：1.0.125 (130)，正式签名、ABI、ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `1b9b77e8e21d51612ff69a5379e9383c6e1372ee8020bab2b0a21236255fb2cb`。
- 归档：`release-archives/v8/`，包含 APK、校验报告、UIAutomator 证据与真机验收记录。
# 十一、v9 批次：正文占位页根因治理与全链路收口

- 版本：`1.0.127+132`，About 页已同步。
- 根因：上游目录会把书名页、卷页、版权页、推荐信等作为普通章节；《老人与海》的书名页正文仅有标题，真实 3189 字正文在下一目录项。原修复只覆盖阅读器，TTS、整本下载和 TXT 导出仍各自处理，容易再次出现空正文或导出异常。
- 统一解析：新增 `ReadableChapterResolver`，阅读器、系统 TTS、整本下载和 TXT 导出全部复用它；只跳过“去掉标题后无内容”的标题占位页，保留版权页、短正文和图片页，真正空响应与网络/解密错误继续明确报错。
- 离线与导出：占位页统一以结构化缓存格式落盘，离线打开可继续解析到下一真实章节；结构化缓存导出时只写可读正文，不再泄漏缓存 JSON；空响应不再写成可反复命中的空缓存。
- 旧缓存自愈：升级前已写入的“结构化空缓存”不再被视为权威离线内容，阅读器会自动重新联网拉取并用真实正文覆盖，避免老用户升级后仍永久停在“正文为空”。
- 目录元数据：章节模型与缓存目录保留 `chapter_word_number`、`chapter_type`，用于诊断和后续源特定规则，但不按字数少直接删章。
- 审查范围：抽查《老人与海》《小王子》《傲慢与偏见》《西游记》《活着》等目录与正文样本；确认占位页、真实短页、图片页及网络失败必须使用不同处理语义，并以共享层固化。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1452 项通过、1 项跳过；Rust 真实内核集成测试单独复验 9 项通过。
- APK：`1.0.127 (132)` 正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验全部通过；SHA-256 `05a7857b5555c86e9857c86d0b6fe298882af145bc3f4aa5125307b52e282836`。
- 真机安装：Redmi K20 Pro（`b2f8e975`）覆盖安装成功，`firstInstallTime=2026-10-19 23:07:26` 未变，数据未清；新版本 `versionCode=132`、`versionName=1.0.127`，App 与 Rust 内核正常启动，日志未见崩溃、未处理异常或 ANR。
- 真机页面验收：解锁后确认《老人与海》从详情页进入书名占位章时自动显示后续真实正文，目录跨章跳转正常；抽查《小王子》《傲慢与偏见》《西游记》正文或版权页均非空。笔记时间戳、分类、多标签、组合筛选面板及实线/虚线/波浪线/荧光笔面板也已在真机确认。
- 真机证据：详情页、占位章后正文、14 章目录、跨章跳转、其他书籍、笔记筛选、划线面板与听书界面均已保存截图/UI XML；logcat 未见崩溃、未处理异常或 ANR。
- 归档：`release-archives/v9/`，包含 APK、校验报告、全量测试日志、安装与锁屏状态证据、验收记录。

# 十二、v10 批次：首页推荐轮换与按书查看笔记

- 版本：`1.0.128+133`，About 页已同步。
- 首页推荐：原「推荐」页每个分类固定展示同一批 6 本，除今日荐读外长期不变。现在基础顺序按日期稳定轮换，每天自动呈现不同组合；新增「换一批」按钮，下拉刷新也会换一组。每个分类推荐位展示 4 本，点「全部」仍可查看该分类完整书单。
- 笔记按书查看：笔记页新增「时间线 / 按书查看」切换。按书模式按最近笔记时间列出所有写过笔记的书籍，显示笔记数、批注/书摘数、涉及章节和最近内容；点击一本书即可进入该书全部笔记的时间线，并自动应用书籍筛选。
- 兼容：按书模式会保留时间、分类、标签和批注/书摘筛选；进入按书视图时清空单书筛选，避免只看到当前一本书而无法切换。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1455 项通过、1 项跳过；首页/笔记/批注/统计相关补充回归 81 项通过。
- APK：`1.0.128 (133)` 正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验全部通过；SHA-256 `f064ca9c3dc033a4c57f3c16ee93f8cbd5cadd93e1417996da4a0b0392d9f489`。
- 真机：Redmi K20 Pro（`b2f8e975`）覆盖安装成功，首次安装时间未变、数据保留；首页「换一批」前后今日荐读由《城南旧事》轮换为《枪炮、病菌与钢铁》，分类推荐位同步变化；笔记页可切到「按书查看」，按书显示笔记数/批注数/书摘数/章节数，点击《小王子》后进入该书两条笔记的时间线。logcat 未见崩溃、未处理异常或 ANR。
- 归档：`release-archives/v10/`，包含 APK、校验报告、全量测试日志、真机截图与 UI XML、验收记录。

# 十三、v11 批次：分类「全部」接入书城多页书目

- 版本：`1.0.129+134`，About 页已同步。
- 问题：首页分类“全部”原先只读取内置书单中的 6 本，刷新只会重排同一组数据。
- 修复：新增 `CategoryBrowsePage`，从书城按分类相关的多个关键词并行检索并去重；首次进入一次合并多页结果，支持“加载更多”和“换一批”。
- 交互：首页顶部分类标签、分类入口按钮和每个分类栏的“全部”都会进入完整分类页；内置 6 本仍作为“精选”数量展示。
- 容错：单个关键词失败不会拖垮整页；全部失败时给出明确重试入口。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1457 项通过、1 项跳过；分类页与首页定向回归 26 项通过。
- 真机：Redmi K20 Pro（`b2f8e975`）覆盖安装 1.0.129 (134)，未卸载、未清数据。古典名著首次载入 40 本，“换一批”后变为 44 本；世界文学 41 本、历史人文 32 本、科普百科 40 本、科幻想象 44 本、成长青春 45 本、诗歌散文 44 本，均不再是固定的 6 本。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验全部通过；SHA-256 `f61dea85123d5dd9cdd643ec8ea43aabd702feb449676c4a89076877c1907384`。
- 归档：`release-archives/v11/`。

# 十四、v12 批次：分类页加载提速（缓存 + 渐进渲染）

- 版本：源码改动，未构建 APK、未提交。
- 问题：首页点“古典名著 / 世界文学…”等分类并查看全部时，分类页固定先转圈约两秒。原因是进入页面要并发搜索 5 个相关关键词，且必须等全部返回才渲染。
- 批次缓存：新增 `CategoryBrowseCache`（内存 + SharedPreferences），按“分类 + 偏移”缓存每批结果。30 分钟内再次进入同一分类直接命中缓存，不请求上游；超过 30 分钟则先用旧结果铺屏、后台刷新（stale-while-revalidate）。最多保留 24 批，避免本地存储膨胀。
- 渐进渲染：`_fetchBatch` 改为哪个关键词先返回就先上屏，不必等 5 条全部结束；上游结果到齐后整批覆盖，顺序与去重规则不变。
- 首屏兜底：冷启动第一次进入时，先用书单里已解析好的本地条目铺满首屏（点击仍走详情页），上游结果返回后覆盖，避免纯白转圈。
- 交互：加载更多也会优先命中缓存；顶部/下拉“换一批”始终强制联网，保证能换到新内容。
- 验证：`flutter analyze --no-pub` 无问题；`category_browse_page_test`、`home_page_test`、`curated_resolver_test` 共 45 项通过，其中新增“缓存命中秒开且不请求上游”“首个关键词返回即渲染”两项用例。
- 真机：Redmi K20 Pro（`b2f8e975`）覆盖安装验证：古典名著首次进入 1 秒内 37 本，二次进入 0.4 秒 38 本，「换一批」45 本正常。

# 十五、v13 批次：分类页不再「自己刷新」、详情页与阅读页去等待

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同一版本号覆盖安装），未提交。
- 问题一：点进分类页后什么都没操作，格子自己整片换了一遍。原因是缓存过期时先铺旧结果、网络返回后 `_showBatch` 整体替换，整片封面同帧重解码、滚动位置跳动。
- 修一：首屏结果改为**追加式合入**（`_adopt`），并对同 id / 同名去重；只有用户主动点「换一批」才整体替换。屏幕不再无端闪一下。
- 问题二：详情页要等 detail 与 directory 两个请求都回来才铺正文，约 1 秒；第二次进同一本书依旧白等。
- 修二：新增 `DetailSnapshotCache`（加密 Hive 盒 `detail_snapshot_v1`，12 小时 TTL，最多 16 本）。启动首帧后预热打开；命中快照直接同帧渲染，网络结果静默覆盖。目录区在等待时只显示一行「正在加载目录」，不再整块转圈。
- 修二补充：详情与目录改为**先到先上屏**——简介、标签、作者不必陪目录一起等；底部「继续阅读」等目录到位后自然出现。
- 问题三：点「继续阅读」进正文，有插图的章节要多等约 1 秒。
- 修三：`_loadChapterText` 不再等待整本目录落盘（`_ensureCatalog`）与章节写入，二者转后台且带版本校验，避免旧文字覆盖新图文；偏好与阅读进度改为与正文并行读取。
- 修三补充：正文解析出来即预热插图（`precacheImage`，与插图组件同一缓存键，最多 6 张）；预取下一章时顺带预热下一章插图。详情页也会在已知续读章节且本地有正文时，提前把该章前 4 张插图拉进缓存。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1454 项通过。新增用例：`detail_snapshot_cache_test`（落盘重开、TTL、淘汰）与分类页「过时缓存留在原位，新结果追加而不是整片替换」。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `5cd72e4d68a9c0fc3b45313ee28ed77759fa816e0a0f820a072bc2bfe43bf2e6`；WSL 原生构建 47.6 秒。
- 真机：Redmi K20 Pro（`b2f8e975`）覆盖安装并拉起，待人工核验三处：分类页进入不再闪刷、详情页首屏、图文正文进入速度。

# 十六、v14 批次：真机实测后的二次提速

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 做法：先在关键路径上加临时 `PERF` 计时探针，用 adb 点按真机取数，再按数据改，最后删掉探针。
- 实测基线（Redmi K20 Pro，`b2f8e975`）：
  - 分类页缓存命中首屏 +15ms；「换一批」联网首条约 +1.0s、整批 +1.3s。
  - 详情页首次进入：detail 与 directory 同在 +473ms 到达；二次进入快照 +1ms。
  - 阅读页首次打开一章：正文 +843ms；正文到位后又被空的划线/批注/段评层触发整章重排，多花约 100ms。二次进入同上路径为 +51ms。
- 优化一（最大收益）：详情页停留期间预热「继续阅读」那一章的正文——本地没有就直接取一次并写进章节缓存，再顺带预热前 4 张插图；没有阅读记录时预热第一章。实测点进去从 843ms 降到 **+23ms**，正文与插图同时到位。
- 优化二：没有划线、没有批注、没有段评气泡时，加载完成不再 +1 排版版本号，省掉每次换章一次多余的整章重排（单章约 50–100ms）。
- 优化三：分类页批次缓存 TTL 由 30 分钟放宽到 6 小时（「换一批」和下拉刷新仍强制联网），避免用户隔半小时再进分类又要等一次上游。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1454 项通过（分类「过时缓存」用例同步改为 7 小时前写入）。
- APK：`2f0154f2d39ed5dc781811e25e6e01a344e585aa3d51fadfee8fe96e3f06c4a5`，正式签名、ABI、原生库与 16 KiB 对齐校验通过；WSL 原生构建 46.3 秒。
- 真机：覆盖安装成功（`lastUpdateTime=2026-10-22 13:03:59`），分类→详情→继续阅读全链路冒烟正常，logcat 无崩溃/未处理异常。

# 十七、v15 批次：把剩下的等待藏起来（骨架屏 + 首页预热 + 插图解码分级）

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 前提：v14 之后各处等待已从「秒级」降到「几百毫秒」，用户仍反馈有轻微卡顿。这一批不再追极限，而是把剩余等待**变得不可感知**，取舍是接受部分预加载。
- 优化一（插图解码尺寸分级）：正文里的插图最宽也就一屏，之前内联和全屏都按 2048×4096 解码，等于每张图多解 2~3 倍像素。新增 `ReaderImageSizing`：正文内联按 1200×2400 解码，只有点开全屏放大才用 2048×4096（`ReaderIllustration.highResolution`）。`reader_page.dart` 的插图预热与 `detail_page.dart` 的续读章节预热同步改用 `ReaderImageSizing.provider(...)`，保证预热缓存键与组件实际使用的完全一致，否则尺寸不同就是另一份缓存、预热白做。
- 优化二（详情页骨架屏）：首开要等一次上游往返（实测约 473ms，网络差更久），之前只有一个 22px 转圈，观感是「卡住 → 突然弹出」。新增 `lib/widgets/detail/detail_skeleton.dart`：作者行、数据卡、简介行、标签、编号行、目录预览都按真实版式摆灰色占位条，900ms 呼吸动画；`MediaQuery.disableAnimations`（含墨水屏）时静止。骨架 `ExcludeSemantics` + `IgnorePointer`，不干扰读屏也不吃点击；「从缓存阅读」按钮移到骨架下方，`detail_read_cached` 这个 key 与错误卡片依旧互斥。
- 优化三（首页分类首批预热）：分类页首批要并发搜 5 个关键词，用户点「古典名著 → 全部」时先看到的仍是等待。新增 `lib/services/category_browse_warmup.dart`：首页渲染完 1.5 秒后，按分类顺序把前 3 个分类的首批（5 个关键词并发、按 id 与书名去重、只留 book/audio）写进 `CategoryBrowseCache`，已在有效期内则跳过。关键词表从 `category_browse_page.dart` 的私有常量抽到这里，页面改为 `CategoryBrowseWarmup.queriesFor(...)`，两处不会漂移。预热失败（整批空）不写空缓存；`catalog` / `categoryLoader` 被注入即测试或离线环境，一次请求都不发。
- 验证：`flutter analyze --no-pub` 无问题；Flutter 全量测试 1460 项通过。新增 `test/category_browse_warmup_test.dart`（去重与过滤、limit 与新鲜缓存跳过、整批失败不写空缓存、页面销毁即停、未知分类回落显示名）与详情页「首开加载态是和真实版式同构的骨架屏」用例。
- 踩坑记录：本机 `dart format` 默认按 tall style（Dart ≥3.7）重排，直接 `dart format lib test` 一次改写了 66 个无关文件。本仓库历史代码是旧风格（短风格），格式化必须带 `--language-version=3.6`，例如 `dart format --language-version=3.6 lib/pages/reader_page.dart`。误改的 66 个文件已还原为 HEAD 内容（逐文件校验 `git diff -w` 为空后才动），最终改动仍只落在 5 个源码文件 + 2 个新文件 + 2 个测试文件上。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `4a3a915cfc3fae0b74a31e417dfdb152f25121cd539e374aba3307c9365b0346`；WSL 原生构建 45.6 秒；38.3 MB。
- 真机：覆盖安装成功（`lastUpdateTime=2026-10-22 13:22:50`）。冒烟：首页正常；点「古典名著 → 全部」0.45 秒内整屏 43 本已铺好，3 秒后画面与首帧完全一致（不再「自己刷新」）；详情页命中快照即时渲染；logcat crash 缓冲为空。

# 十八、v16 批次：上下滚动模式向前跨章无缝

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 问题：上下滑动模式下，处在某章开头继续往下拖，本应接上上一章末尾；实际先卡一下，然后跳到上一章的**其他位置**。左右翻页（分页模式）没有这个问题。
- 根因（两处叠加）：
  - 滚动窗口只会**向后**长（预取下一章追加到尾部），向上跨章走 `_prev(startAtEnd: true)`，而窗口里没有上一章，于是回退到「整章加载 + 版面重建」，就是那一下卡顿。
  - 窗口判据旧的是 `_scrollWindowBookChapter != _scrollWindowKey`（以「当前章」为键）。视口一越过章界，当前章变了，整个窗口被重建；读者被留在新列表的同一像素偏移上，于是落到上一章的别处。
- 修一：窗口判据改成「当前章是否在窗口里」（`indexWhere` 找当前章，`_scrollActive` 以当前章为准），跨章不再整块重建窗口。
- 修二：新增 `_prefetchScrollSegmentBefore()`——把上一章排好插到窗口最前面，`_scrollActive += 1`，同时 `jumpTo(offset + segment.extent)` 补偿新增高度；章节极短、旧 `maxScrollExtent` 装不下补偿位置时，post-frame 再跳一次。失败静默，真拉到顶时仍由 `_prev()` 兜底整章加载。
- 修三：`_maybeScrollPrefetch()` 增加向上触发——窗头上沿离视口不足 1.5 屏就把上一章排好插入，于是拖到章首时内容已经在手里。
- 附带重构：把原 `_prefetchScrollSegment` 里的「加载 + 排版」抽成 `_measureScrollSegment(index, spec)`，前后两个方向共用同一套测量逻辑；`_scrollBusyBefore` 与 `_scrollBusy` 分开，前后预取互不阻塞。
- 验证：`flutter analyze` 无问题；Flutter 全量测试 **1462** 项通过。`test/reader_seamless_scroll_test.dart` 新增 2 个用例：章首往下拖直接接上一章末尾且不重新加载整章（`firstChapterLoads == 1`）、跨章向前滚时窗口只增不减（`maxScrollExtent` 单调不减）。
- 格式化的新坑：`reader_page.dart` 里已用上 null-aware elements（`?currentChild`）、需要 Dart ≥3.8，`--language-version=3.6` 会直接解析失败。本批改为「默认 `dart format` 跑一份副本、`diff` 确认新增代码无差异」来校验，不动历史旧风格段落。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `ee872b2888cc09a74fb261e7d2b2a42ab8bebb86d76eb4b08776b9a0b6f05723`；WSL 原生构建 41.8 秒；38.3 MB。
- 真机（Redmi K20 Pro `b2f8e975`）：切到「上下滚动」后从 `目录 → 第一回` 进入章首，往下拖一屏，上一章《关于本书的整理情况》的结尾（`人民文学出版社编辑部 / 一九七三年八月`）直接接在标题上方出现，无卡顿、无跳动；继续往上两屏顺畅进入上一章正文；反向下滑两屏回到同一像素位置（前后截图完全一致）。`lastUpdateTime=2026-10-22 13:53:43`。

# 十九、v17 批次：笔记重构（封面视图 + 自定义批注类型 + 划线查看）+ 划线预选修复

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 笔记页「按书查看」改成与首页一致的封面网格：复用 `homeCardWidth` / `homeGridDelegate` 与 `StoryCover`（5:7 封面、右上角笔记数角标、标题两行、统计行），不再是文字列表。
- 笔记页新增第三个视图「划线」：把 `ReaderRangeUnderline`（范围划线）与 `ReaderUnderline`（早期整段划线）合并成一条按时间倒序的列表，带线型标签（实线/虚线/波浪线/荧光笔）、书名、时间、原文两行与章节名；二级 chip 切换「全部 / 划线 / 荧光笔」，再按书 chip 过滤；点一条可直接跳到原文那一句（`startOffset`）。
- 自定义批注类型：新增 `lib/services/reader_marker_type_store.dart`（加密 Hive 盒 `reader_marker_types_v1`，单条 `types` 列表，最多 24 条、最近优先、同名覆盖），编辑器里的「批注标记」变成「内置 4 预设 + 用户自定义 + 已落库角标」三点色 chip；「新类型」可现场命名 + 选色，保存时自动记忆。笔记页顶部与筛选面板都按「批注类型」维度筛选（`NoteTimelineFilters.markerKey`）。
- 划线预选 bug：之前在正文里点「划线」出现预选项后，若用户点别处，预选被静默丢弃。现在 `reader_page.dart` 的 `onTapUp` 在 `_underlinePanelOpen` 时先按当前 `_markChoice`（线型 + 颜色）落笔再收起面板；面板标题行补「确定 / 取消」两个显式按钮。
- 界面整理：视图切换条改为三项（时间线 / 按书查看 / 划线）；顶部筛选区重排为「内容 chip 行（全部/批注/书摘 + 筛选）+ 批注类型横向 chip」；空态按模式区分；划线记录的书名先取笔记里的书名，再回落到阅读历史与首页书单解析缓存（`CuratedResolver.cached`），封面同样从历史/书单缓存补，查不到才用几何封面兜底。
- 验证：`flutter analyze` 无问题；Flutter 全量测试 **1472** 项通过（10 跳过）。新增 `test/notes_page_test.dart`（4 例：类型 chip 筛选、划线视图 + 荧光笔/划线切换、按书封面卡片、划线空态）、`test/reader_marker_type_store_test.dart`（4 例：catalog 去重、fromMap 兜底、add 排序/覆盖/上限、remove）、`test/reader_paragraph_actions_test.dart` 新增 2 例（点正文别处按预选落笔、面板内「取消」不落笔）。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `544d844eb58df9e40fe3118693644f43a96dd657cded86348c2652f106fdb446`；38.3 MB。
- 真机（Redmi K20 Pro `b2f8e975`）冒烟：笔记页三视图正常，「按书查看」四本书封面与首页一致（西游记/三体/小王子/草房子），批注类型 chip 筛选生效；「划线」视图 6 条记录书名/章节名齐全；正文长按 → 划线出现预选面板（含确定/取消），点正文别处后按预选「虚线 + 琥珀」落笔并提示「已划线」，笔记页记录数 5 → 6；批注编辑器里「新类型」+ 取色可用。

# 二十、v18 批次：把听书页的配色语言铺到其余界面

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 参照对象：听书详情页（`lib/widgets/audio/audio_sections.dart`）的取色规律——卡片用 `palette.soft` 铺底 + 12px 圆角；未选 chip 是比底色更深一层的 `line@35%`，选中才抬成 `surface` 并加一圈 `accentText@55%` 细描边、文字转主色；正文文字 ink、说明文字 muted、强调数字/进度用 accent。
- `HomePalette` 新增三个统一 token：`chipFill`（未选 chip 底色，墨水屏回落纯白）、`chipSelectedFill`（选中 chip 底色）、`chipBorder(selected)`（选中主色描边 / 未选透明），墨水屏下退化为白底 + 黑色描边，不引入灰阶。
- 笔记页：视图切换、内容 chip、批注类型 chip、划线线型 chip、按书 chip 全部改用新 chip token；「筛选笔记」弹层从米黄纸面改成 `palette.canvas` 深色面板（标题 ink、说明 muted、应用按钮主色、下拉与输入框 `soft` 填充 + 细描边）；筛选计数角标由橙色改为品牌绿；时间线里引用原文的暖棕色文字改为 muted。
- 章节缓存页（`cached_books_page.dart`）：原来整套 Material `Card` / `ListTile` 默认样式，改为 `palette.canvas` 背景 + `soft` 汇总卡 + 「细描边 + 圆角 14」的书籍行；封面改用首页同款 `StoryCover`（无封面时几何兜底），导出/删除图标换成 Lucide 并统一 muted 色，进度环用主色；空态换成 `soft` 圆底 + Lucide 图标。
- 系统朗读设置（`system_tts_settings_page.dart`）：说明卡 `soft`、引擎下拉与语速卡「surface + 细描边」、语速值做成主色小徽标、Slider 用主色（轨道 `line`）、底部按钮改主色描边。
- 听书模式页（`listen_mode_page.dart`，当前仅测试引用）：`#121212` 背景改 `palette.canvas`，橙色 `#FA6725` 控件全部换成品牌绿，倍速药丸沿用新 chip 规则。
- 阅读统计页（`stats_page.dart`）：笔记相关的红色 `#D64545` 改用品牌点缀色 `AppTheme.highlight`，与全局色板一致。
- 验证：`flutter analyze` 无问题；Flutter 全量测试 **1472** 项通过（10 跳过）；`notes_page_test`、`cached_books_page_test`、`cached_books_page_export_test`、`stats_page_widget_test`、`listen_mode_page_test`、`system_tts_test`、`audio_listening_boundaries_test` 均通过。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `09933a5704ccc20b614526c512cbc40a484a618f21943fd8169a6a5939c01585`；38.5 MB。
- 真机（Redmi K20 Pro `b2f8e975`）冒烟：章节缓存页 27 本封面卡片与听书页同一套暗底 + 细描边质感；笔记页 chip 选中态变成亮底 + 绿色描边；筛选面板为深色 sheet，选中分类/类型/标签与「应用」按钮都是品牌绿；`lastUpdateTime=2026-10-22 17:52:51`。

# 二十一、v18.1：我的 / 设置 / 阅读统计收口到同一色系

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 「我的」快捷入口：笔记 / 章节缓存 / 应用设置 / 关于我们原本是红蓝绿紫四色图标，改为统一的 `palette.soft` 卡片 + `accent@14%` 图标底 + 主色图标，靠图标形状和文字区分入口；「设置」胶囊保持 soft + 细描边。
- 「我的」统计卡片（`stats_page.dart` 内嵌）：`_Card` 从 `scheme.surface + outlineVariant` 改为 `palette.soft` 无描边；指标块从 `surfaceContainerLow` 改为比卡片更深一层的 `line@45%~55%`，数值 ink、标签 muted，标题竖条改品牌绿。
- 阅读统计页顺手修一个显示缺陷：今日/本月/总计的数值原先被省略号截断（「3 小时 17…」），改为 `FittedBox` 缩放，能完整显示「3 小时 17 分钟」。
- 设置页分类图标：原来 6 个硬编码色（青绿/珊瑚/紫/蓝/绿/靛）且与分类顺序错位，改为按标题取色——外观/数据用品牌绿，听书用品牌点缀色珊瑚橙，服务/关于退到 muted，形成层级；图标底统一 `accent@13%`、圆角 11。
- 验证：`flutter analyze` 无问题；Flutter 全量测试 **1472** 项通过（10 跳过）。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `15b65a77da9531fc34c9f4f2a69db1b0cc5858a0cff8a35ad5f6e424e5d1d13d`；38.5 MB。
- 真机（Redmi K20 Pro `b2f8e975`）冒烟：我的页四个入口同色系、统计数字完整显示；设置页图标层级（绿 / 珊瑚 / 灰）符合预期；`lastUpdateTime=2026-10-22 18:37:43`。

# 二十二、v19 批次：全应用锁定竖屏

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 问题：手机横过来时，App 整体跟着转成横向排版（首页、分类、详情、阅读正文都会重排），横屏在小说阅读场景里没有收益，只带来一次重排抖动。
- 双层兜底：
  - Flutter 层：`lib/main.dart` 在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用 `SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])`，全局只接受竖屏。
  - 系统层：`android/app/src/main/AndroidManifest.xml` 的 `MainActivity` 增加 `android:screenOrientation="portrait"`，让 Activity 在启动瞬间就是竖屏，不会先转一次再被 Flutter 拉回来。
- 影响面：只锁方向，不改布局、不改交互；平板上仍按竖屏呈现；阅读页左右翻页手势、面板弹出都不受影响。
- 验证：`flutter analyze lib/main.dart` 无问题；Flutter 全量测试 **1472** 项通过（10 跳过）。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `68df01270a1b20885ad6a23ae36c7e29fbd934582695ed3908c1b858d406b7f1`；38.5 MB。
- 真机（Redmi K20 Pro `b2f8e975`）冒烟：`settings put system user_rotation 1` 强制系统转 90° 后，截图仍是 540×1170 竖屏，首页完整显示；`dumpsys window` 里 `mCurrentAppOrientation=SCREEN_ORIENTATION_PORTRAIT`；核验后已恢复 `accelerometer_rotation=1` 并删除 `user_rotation`。`lastUpdateTime=2026-10-22 18:42:46`。

# 二十三、v20 批次：听书详情/正文联动 + 可拖动胶囊 + 句级高亮

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 听书详情页正文区改版（`lib/widgets/audio/audio_sections.dart` 新增 `AudioNarrationView`，替换原 `AudioExcerpt`）：
  - 有字幕轨时只显示「上一句（灰）/ 当前句（主色竖条 + 加粗，key `audio_narration_current`）/ 下一句（灰）」，随播放位置实时滚动，不再一次性铺一大段，用户能一眼看出正在念哪一句。
  - 没有字幕轨的录音回退成 3 行章节摘要（key `audio_narration_excerpt`），不会再空一块。
  - 整卡 `onDoubleTap` → 直接进正文（`_openReaderFromAudio`），底部提示从「双击查看全部」改为「双击进入正文」，右侧保留「进入正文 >」按钮。
- 正文页朗读句高亮（`lib/pages/reader_page.dart` + `lib/widgets/reader/reader_chapter_layout.dart`）：
  - 新增 `narrationTextRange(layout, text)`：`ListeningSession.narrationText`（当前字幕句）先在正文里整句精确匹配，再忽略空白/标点匹配，最后退到前 12 字前缀；命中就只给那一句上色。
  - 新增 `narrationBlockAtProgress(layout, progress)` 兜底：整句跨段落或对不上原文时，按朗读进度落到所在段落整段高亮，至少让读者知道读到哪一段。
  - 暂停朗读时高亮保留（读者常停下来对照原文），只有停止听书（`ListeningSession.clear()`）、切章或换书才清空；排版完成后补一次 `_syncNarrationHighlight`，所以「暂停着进正文」也能立刻看到高亮。
  - `AudioPlaybackController` 每次发布会话状态时带上 `narrationText: _subtitles.cueAt(position)?.text`，`ListeningSession` 新增该字段并纳入结构变化判定。
- 听书悬浮胶囊（新文件 `lib/widgets/audio/listening_capsule.dart`，`audio_playback_scope.dart` 内替换原底部通栏 mini bar）：
  - 232×48 胶囊，`palette.soft` 底 + `palette.line` 描边 + 阴影，浮在 Overlay 上（在阅读页里也不占正文行高）。
  - 可自由拖动：`Positioned` + `onPanUpdate`，限制在可视区内；修复了快速滑动时用同一帧旧坐标导致「手指走完胶囊只挪一点」的 bug（改成以最新落点累加 delta）。
  - 保留暂停/播放（`audio-mini-toggle`）与叉号关闭（`audio-mini-close`），点标题回听书页（`audio-mini-open`）。
  - 新增「听书设置」（`audio-mini-settings`）：定时关闭 / 语速 / 音色三行，和听书页共用 `_showListeningSettings`；系统朗读则进 `SystemTtsSettingsPage`。胶囊在 Navigator 之外，弹层用 `widget.navigatorKey.currentState?.overlay?.context`。
- 验证：`flutter analyze` 无问题；Flutter 全量测试 **1483** 项通过（10 跳过）。新增 `test/audio_narration_view_test.dart`（3 例）、`test/audio_playback_scope_test.dart` 补 2 例（三行设置项、胶囊可拖动）、`test/listening_sentence_highlight_test.dart` 补 5 例（`narrationTextRange` 3 例 + `narrationBlockAtProgress` 2 例）、`test/reader_page_test.dart` 补「有声书朗读时正文段落会被高亮」（滚动模式下长章节，含暂停保留、停止后清除）。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `4079ef3e355796e345459eba8f326ce8328256588a786db8500c300bfda5ae67`；38.5 MB。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 听书详情页卡片显示「上一句 / 当前句（绿竖条加粗）/ 下一句」，念到新句时卡片实时换行（截图 19:46）。
  - 点「进入正文」直接落到正在朗读的《冬阳 童年 骆驼队》，正文里「但是拉骆驼的说，他们从门头沟来……」整句带琥珀色底（截图 19:51）。
  - 暂停后进正文，高亮仍在；胶囊显示播放箭头。
  - 胶囊拖动：从左下拖到右中并保持，位置被记住（截图 19:39/19:40 前后对比）。
  - 胶囊「听书设置」弹出「定时关闭 / 语速 / 音色」三行，音色显示当前「甜美少女音」。
  - `lastUpdateTime=2026-10-22 19:55:06`（含格式化后的最终包）。

# 二十四、v21 批次：听书页重构（固定布局 + 可滚正文 + 从本句听 + 页数）

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 问题：详情页只显示三行字幕，句子长短不同会让那块区域高度跳动，把下方播放控件顶来顶去；同时一眼只能看三句，无法像读正文一样回看。
- 布局（`lib/pages/audio_page.dart` + `lib/widgets/audio/audio_sections.dart`）：
  - 删除 `AudioNarrationView` 三行卡片与旧 `AudioToneSection` 音色大卡（含 `_AudioToneChip`、`AudioRelatedRow` 死代码）。
  - 新增 `AudioNowPlayingHeader`：固定高 84，左侧 60×80 小封面，右侧当前章节（两行截断）+「书名 · 第 n / N 章」+ 目录/进正文按钮。
  - 新增 `AudioNarrationBody`：整章逐句铺开，`SingleChildScrollView` 上下滚动，当前句主色竖条 + 淡底 + 加粗，已读句变淡；自动跟随当前句（`ensureVisible`，用户手动拖动后暂停跟随 8 秒）；无字幕轨回退章节摘要段落；不加载任何图片。
  - 页面改为固定 Column：头部 → `Expanded(正文)` → 页数/全书进度 → 状态行（固定 50 高，错误文案与「重试」并排，不再撑出边界）→ 操作行 → 进度条 → 传输控件 → 紧凑音色条。句子长短、标题长短都不再推挤下方控件。
  - 正文下方左侧新增「第 X / Y 页」（按字幕字数折算），右侧保留「全书 NN.N%」。
  - 长按任意一句弹出「从本句听」，跳到该句时间点并开始播放。
  - 音色条压成一行只显示当前音色（如「甜美少女音」），右侧保留「边听边读」；点它仍打开原「声音设置」弹层。
- 修复：
  - 进度条 `Slider` 在「弹层关闭 + 换版本同帧」时触发 Flutter 语义断言（`identical(childRenderObject, parentRenderObject)`），用 `MergeSemantics` 包住修复（固定布局让 Slider 始终可见后才暴露）。
  - 头部「目录」按钮 tooltip 改为「打开目录」，避免与底部传输栏的「目录」重名。
  - 迷你胶囊显示判定改为「只被真正的页面路由盖住才显示」：新增 `AudioRouteWatcher`（`NavigatorObserver`），弹窗/菜单/底部面板不再让胶囊冒出来盖住听书页控件；`ModalRoute.isCurrentOf` 仅作为未接入观察者时的回退。
- 测试：`flutter analyze` 无问题；Flutter 全量测试 **1486** 项通过（10 跳过）。更新 `test/audio_narration_view_test.dart`、`test/audio_linked_voices_test.dart`、`test/audio_page_test.dart`、`test/audio_related_navigation_test.dart`、`test/review_fix_b12_test.dart`、`test/ui_review_regressions_test.dart` 以适配新布局与相关作品移入「播放设置」弹层；`test/audio_playback_scope_test.dart` 新增「弹层不唤醒胶囊」用例。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `12fdebdbf925fe116e7be933b6dcca53668f30bc58dc8eb22d6a7c764db2caba`；36.7 MiB。
- 真机（Redmi K20 Pro `b2f8e975`）核验：小封面 + 右侧「冬阳 童年 骆驼队 / 城南旧事 · 第 7 / 16 章」；正文可上下滚动，底部「第 14 / 32 页」「全书 43.6%」；长按句子出现「从本句听」，点击后跳到 03:59 并开始播放、当前句高亮跟随；滚动/长按时下方控件位置不变；打开「播放设置」弹层时迷你胶囊不再出现。

# 二十五、v22 批次：听书胶囊双形态 + 护眼弹窗置顶 + 切章音频链路

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 听书胶囊显示逻辑（`lib/widgets/audio/audio_playback_scope.dart`、`lib/widgets/audio/listening_capsule.dart`、`lib/pages/reader_page.dart`）：
  - 新增 `ReadingCapsuleHost`：阅读页进入/退出、工具栏显隐、对话框打开三类信号共同决定胶囊形态。
  - 工具栏展开 → 完整可拖动胶囊（232×48）随工具栏一起出现；工具栏收起 → 底部收紧成 128×38 小按钮，文案「停止听书 / 继续听书」，点击即暂停或继续。
  - `_ReaderToolbarPresence` 负责把工具栏可见性写回 host；非阅读页仍保留完整胶囊。
- 护眼提醒层级（`lib/pages/reader_page.dart`）：
  - `_showEyeCareReminder()` 用 `try/finally` 置 `ReadingCapsuleHost.instance.setDialogOpen(true/false)`；弹窗期间两种胶囊都不渲染（`suppressed = host.dialogOpen`），弹窗完整覆盖页面元素与胶囊。
  - `ReaderPage.eyeCareInterval` 为 45 分钟连续阅读。
- 切章音频无法播放（根因 + 修复）：
  - 真机 logcat 定位：城南旧事第 8 章阅读版 playinfo 返回 `QUERY_CHAPTER_LOCK_ERROR`（付费锁章），`/api/v1/audio/play` 兜底也被上游 401/403/429 拒绝；三国演义前折页/书名页/版权页本身无音源（`未获取到音频地址`）。**不是播放器重建问题，是上游对部分章节不提供音频**，不绕过付费机制。
  - `lib/services/api_client.dart`：新增 `audioPlaySource()`（`/api/v1/audio/play` 旧 mget 桥）。
  - `lib/services/audio_playback_controller.dart`：`_loadSourceWithRetry` 在锁章/无音源时尝试 legacy 源；`_audioFailureText()` 区分「本章为付费内容，暂不可听。」与「本章暂无音频内容。」；`_openChapter` 新增 `skipEmptyDirection` / `skipEmptyRemaining`（上限 12），只对「无音源」沿同方向跳过前置页，锁章不跳过；新增 `_switchChapter(int direction)` 统一上一章/下一章、系统媒体 next/prev、自动下一章。
  - `lib/pages/audio_page.dart`：上一章/下一章、目录跳章走页面级 `_switchChapter` / `_openChapterFromCatalog`；用户主动切章遇「付费/暂无音频」时自动转系统朗读（`_autoTtsPending` / `_autoTtsChapter`），不再停在死页；状态行提供「系统朗读」+「重试」。
  - `lib/services/system_tts.dart`：修复 `SystemTtsBook.load` 把空 `initialContent` 当正文导致「本章没有可朗读的文字」；新增 `SystemTtsPlayback.started`，首个章节首句交给引擎后完成，关闭时也完成。
  - `audio_playback_scope.dart`：`startSystemTts` 等 `session.started`（最长 40 秒），失败或 `session.error != null` 时关闭并抛错，听书页不再误关闭。
- 收起态小按钮兜底：音频未就绪（锁章/加载失败）时点小按钮直接进听书页，不再出现「点了没反应」的死按钮。
- 兜底跳转（`lib/pages/audio_page.dart`）：自动转系统朗读成功后不再退回详情页，改为 `pushReplacement` 到同一章的正文页 —— 朗读句高亮、胶囊控件都在正文里，听书中途不会掉出界面。
- 测试：`flutter analyze --no-pub` 无问题；Flutter 全量测试 **1492** 项通过（10 跳过）。新增 `test/audio_page_test.dart`「无音源前置页自动跳过」「锁章不跳过」，`test/system_tts_test.dart`「空 initialContent 仍加载章节正文」，`test/reader_eye_care_test.dart` 通过。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `397e5e5ccbe090eb653678aaa8f29c9a496708fdbe767589c9f8ce9431d04626`；38,458,951 字节（36.7 MiB）。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 工具栏展开显示完整胶囊；收起后底部为「停止听书」小按钮，点击暂停变「继续听书」，再点恢复播放。
  - 系统朗读进行中把护眼提醒改短触发：弹窗完整压在正文与胶囊之上，底部胶囊不可见；点「再看 15 分钟」后胶囊恢复；验证包已改回 45 分钟。
  - 听书页第 7 章点「下一章」→ 第 8 章付费锁定 → 自动转系统朗读并落到第 8 章正文页（不再退回详情页），段落高亮 + 底部「停止听书」，点按可暂停/继续。
  - 城南旧事第 8 章提示「本章为付费内容，暂不可听。」并可点「系统朗读」；第 8 章「下一章」自动转系统朗读落到第 9 章「我们看海去」，当前句高亮。
  - 三国演义第 3 章「下一章」跳过第 4/5 章（前折页、书名页），落在第 6 章「版权页」并播放 04:04 音频。

# 二十六、v23 批次：系统朗读听书页与有声书同构 + 分句高亮 + 正文小窗渐隐 + 页数/胶囊落位

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 系统朗读与作品自带音频共用同一套听书详情页（`lib/widgets/audio/system_tts_controls.dart`、`lib/widgets/audio/audio_sections.dart`）：
  - `SystemTtsPlaybackPage` 与 `AudioPage` 同构：顶部 60×80 小封面 + 右侧当前章节（两行截断）+「书名 · 第 n / N 章」、整章逐句可滚正文（不加载任何图片）、页码与全书进度、固定 46 高状态行（「正在朗读 · 第 i / N 句」/ 错误 + 重试）、目录 / 上一章 / 播放 / 下一章 / 朗读设置、底部音色条 +「边听边读」。
  - `SystemTtsPlayback` 新增 `text` / `sentences` / `sentenceIndex` / `sentenceRange` / `speakFrom`；每次只把一个分句交给系统 TTS 引擎，`narrationText` 同步发布，正文高亮与朗读严格同句。
  - 删除系统朗读胶囊「更多」里未实现的「使用作品自带音频」入口，只保留「朗读设置 / 关闭朗读」。
- 正文高亮改为按句（`lib/widgets/reader/reader_chapter_layout.dart`、`lib/pages/reader_page.dart`）：
  - 新增 `narrationTextRangeNear`，阅读页优先使用 TTS 发布的句子范围；系统朗读不再一次性高亮整段或多段。
- 正文小窗渐隐（`NarrationFade`）：
  - 高度 26 → 44，渐变 `colors: [edge, edge, transparent]`、`stops: [0, 0.28, 1]`，首行/末行以淡出收尾，不再被硬切只露半行。
  - 正文内边距 `20,6,20,12` → `20,18,20,20`，上下留出渐隐呼吸区。
- 正文左下角页码（`lib/widgets/reader/reader_status_bar.dart`）：
  - 由时间改为「读到 X 页 · 共 Y 页 · 剩 Z 页」（key `reader-page-progress`），右侧仍为「全书 NN.N%」；听书时状态行给胶囊预留一条带子。
- 收起态胶囊落位（`lib/widgets/audio/audio_playback_scope.dart`）：
  - 底部「继续听书 / 停止听书」小按钮改为 `bottom: padding.bottom + 4`，整颗落在状态行内，不再一半压正文、一半压系统手势条。
- 胶囊层级补修（同文件）：
  - `AudioRouteWatcher` 新增 `popupOpen`（栈顶为 `PopupRoute` 即弹层）；弹窗/底部面板/菜单打开期间胶囊整体隐藏——阅读页「听书 / 系统朗读」选择面板不再被胶囊盖住。
- 测试：`flutter analyze --no-pub` 无问题；`audio_playback_scope_test`、`audio_page_test`、`listening_sentence_highlight_test`、`system_tts_test` 共 **85** 项通过。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `55b42d4bb69ec97eaa10a482da8809c1854a47ebaf919ae853e698b0119d2c94`；38,524,635 字节（36.7 MiB）。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 正文 → 听书 → 「听书 / 系统朗读」面板：胶囊已隐身，两行选项完整可见可点。
  - 系统朗读正文高亮逐句跟随（「胡同里踢球，」「天气又干又冷。」），不再整段/多段。
  - 点胶囊进入的详情页与作品自带音频页同一套布局：封面 + 章节、可滚正文、左下「第 1 / 6 页」+ 右「全书 31.4%」、「正在朗读 · 第 4 / 90 句」、传输控件与音色条。
  - 详情页「下一章」：第 6 → 7 章，正文加载完成且朗读继续（第 3 / 57 句）。
  - 正文左下角显示「读到 36 页 · 共 112 页 · 剩 76 页」。
  - 正文小窗上下边缘文字为渐隐淡出，无硬切半行；透明胶囊不再压在传输控件上。
- 已知口径差异（不阻塞验收）：听书详情页的「第 X / Y 页」按自身字幕字数估算（前言 1/6），与正文页 `_maxChapterPages` 的分页估算不完全一致。

# 二十七、v24 批次：沉浸式阅读 + 状态行改造 + 按钮/菜单重排 + 听书跟随修复

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 听书底部按钮删除（`lib/widgets/audio/listening_capsule.dart`、`audio_playback_scope.dart`）：
  - 删掉收起态的 `ListeningCapsuleCollapsed` 小药丸；工具栏收起时不再出现「继续听书 / 停止听书」，只保留可拖动的完整胶囊。
- 状态行改造（`lib/widgets/reader/reader_status_bar.dart`）：
  - 左下角改为「当前页/总页 百分比」，如 `9/1048 0.8%`，不再显示「读到 / 共 / 剩」长文案。
  - 右下角改为电量：电池图标 + `100%`，充电时用 `battery_charging` 图标。
  - 行高按 compact / 分页行 / 电池行固定预留，切换日夜不再改变正文可用高度（修「上下滑动模式首次切日夜正文跳一下」）。
- 沉浸式系统栏（`lib/pages/reader_page.dart`）：
  - 工具栏收起且页面在前台时 `SystemUiMode.immersiveSticky`，隐藏状态栏与小白条手势导航；工具栏出现 / 弹层打开 / 离开页面时恢复 `edgeToEdge`，并在退出阅读时兜底还原。
- 行内批注落位（`lib/widgets/reader/reader_chapter_layout.dart`）：
  - 批注块按「批注行的行尾」切分正文：该行之后插入批注卡片，后续正文从下一行继续，不再一律挂到整段末尾。
- 听书跟随（`lib/pages/reader_page.dart`）：
  - 按排版里的真实行位置换算目标，朗读行顶部落在视口约 1/3；`animateTo` 380ms `easeOutCubic` 缓动，替换原来逐 tick `jumpTo` 的「一点点突然下降」。
  - 目标位置夹紧后仍保证高亮行在视口内，章末也不会把正在读的行送出屏幕。
- 阅读工具栏（`lib/pages/reader_page.dart`）：
  - 去掉右上角「收起阅读菜单」折线按钮，改为「加入书架 / 已在书架」（`reader-toolbar-shelf`），与详情页、听书页文案统一。
- 详情页按钮互换（`lib/pages/detail_page.dart`、`lib/widgets/detail/detail_read_bar.dart`）：
  - 底栏左侧「下载」改为「加入书架」，右上角「加入书架」改为「下载」；
  - 「加入书架」作为次级主操作加大：图标 22、字号 11.5、内边距 8/4。
- 选区菜单（`lib/widgets/reader/reader_paragraph_menu.dart`）：
  - 左侧常驻「从本段开始听书」（单独加宽 84），不再取决于当前段是否有时间轴，四个常规动作（复制 / 划线 / 批注 / 书摘）仍在其右。
- 关闭听书后的返回（`lib/pages/audio_page.dart`）：
  - 不再渲染「本次播放已关闭」整页黑屏；关闭听书后按返回直接回到小说详情。
- 测试：`flutter analyze --no-pub` 无问题；`reader_interface_test`、`reader_annotation_layout_test`、`audio_playback_scope_test`、`detail_page_test` 共 51 项通过。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `d64dd77fcc33f39201f27bd023fcc95cad778ce118b42956171b177088d561b6`；38,524,631 字节（36.7 MiB）。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 正文沉浸态：顶部系统状态栏与底部手势条都隐藏；点开工具栏两者恢复。
  - 左下角 `9/1048 0.8%`，右下角电池 `100%`。
  - 日夜来回切换后正文行位置与切换前一致（逐行像素比对 offset=0）。
  - 工具栏右上角为书架图标，无折线收起按钮。
  - 长按正文弹出「从本段开始听书 / 复制 / 划线 / 批注 / 书摘」五个动作。
  - 系统朗读时高亮句位于屏幕中部可见区域；工具栏收起后底部没有「停止听书」按钮。
  - 打开听书详情 → 返回 → 胶囊关闭听书 → 再返回，直接回到小说详情，无黑屏页。

# 二十八、v25 批次：工具栏显隐不再推动正文（覆盖式工具栏）

- 版本：源码改动 + 真机验证包（`1.0.129 (134)` 同版本号覆盖安装），未提交。
- 问题：点开/收起工具栏时正文整体上下跳；根因是工具栏显隐会切换系统栏（`immersiveSticky` ↔ `edgeToEdge`），`viewPadding` 随之归零再恢复，SafeArea 内的正文视口高度变了一次，整章重新分页。
- 冻结安全区（`lib/pages/reader_page.dart`）：
  - `_stableInsets` 首帧取真实 `viewPadding`，之后只取见过的最大值；`MediaQuery.padding` 始终喂这个冻结值。系统栏显隐不再改变正文视口高度，工具栏只是滑上来盖住正文。
- 章首让位（唯一例外）：
  - 工具栏高度不再写死 56，改为用 `GlobalKey` 实测（`_toolbarHeight`）；`_toolbarLift = 工具栏高度 - 状态栏安全区 - 正文上边距`，让首行正好落在工具栏下沿。
  - 让位用 `ClipRect + Transform.translate` 平移绘制，不改视口高度：改 padding 会触发整章重新分页、按段落对齐回填，关工具栏时文字仍会跳几像素。
  - 让位是「打开那一刻锁存」的（`_liftForToolbar`）：章首展开后往下滚不会再掉回去；中途收起时把滚动偏移同步减去这段高度，正文视觉位置分毫不动（真机逐行像素比对 offset=0）。
  - 分页（左右滑动）模式不做让位，整页平移会切掉页面最后一行；该模式本来也不会推动正文。
- 工具栏自身：不再被让位 padding 影响（否则 SafeArea 会把让位吃掉，量出的高度越量越大，正文被越推越远）。
- 测试：`flutter analyze` 无问题；`reader_interface_test` 新增「章首让位只发生一次、滚动中不掉、关闭时零位移」用例，与 `reader_annotation_layout_test` 共 22 项通过；`reader_system_bars_test` 的 2 条「开菜单后视口不变」断言按新语义放宽为「视口尺寸不变且不越安全区」。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `840078ba1bcd93ff42d5eb3a5f02548958f78ae8ab910604ca7bb6aa9717660d`；38,524,635 字节。
- 真机（Redmi K20 Pro `b2f8e975`）核验（逐行像素比对）：
  - 上下滑动、章节中段：反复开/关工具栏，正文行坐标完全一致（offset=0），状态栏与手势条只在工具栏出现时显示。
  - 左右翻页：同样反复开/关，正文零位移。
  - 章首：展开工具栏后首行「版权信息」落在工具栏下沿（实测工具栏 272px，首行 299px），不再被遮；关掉后整页回到原像素位置。

# 二十九、v29 批次：我的页「每日记录」并入阅读报告 + 代码精简

- 版本：`1.0.129 (134)` 覆盖安装；已提交。
- 问题：我的页「阅读热力图」与「每日记录」功能重复；前者点进去是阅读报告，后者只在首页列 14 天，同一份日聚合被写了三遍（热力图 / 每日记录 / 报告页各遍历一次）。
- 收敛方案：
  - 服务层新增 `ReadingReport.dailyIn(range, {includeEmpty})` 与 `reportDayLabel()`（`lib/services/reading_report.dart`），逐日明细与「今天/昨天/周几」文案只此一份。
  - 报告页新增「每日阅读」卡片（`_DailyReadingCard`）：按天列出时长 + 相对进度条，默认 14 行、超出可展开；周档补齐 0 分钟的天，年/总档只列有记录的日子；「阅历」档不出现。
  - 真机复验后两处微调：只列到今天（不再把本周未来的周六/周日列成「--」）；时长列改为等比缩放，系统字号调大时也不再截成「5小时16…」。
  - 我的页删除 `_DailyRecordsCard`、`_RecentCoversCard`（与「最近阅读」同数据重复）、`_daySubtitle`；热力图卡片副标题改为「最近 16 周 · 点击查看每日阅读」。
  - `_computeDayMinutes` 改为复用 `buildBookDayMinutes + sumDayMinutes`；`_dayKey` 统一为 `reportDayKey`。
- 代码精简：
  - 删除无人 import 的 `lib/services/comic_page_layout.dart`、`lib/services/playback_issue.dart`。
  - 删除全项目零引用的旧首页组件：`ambient_backdrop.dart`、`home_feed_states.dart`、`home_hero.dart`、`home_resume_card.dart`（共 769 行）。
  - 移除 pubspec 中已无任何 `package:hive` 引用的 `hive` / `hive_flutter`（代码统一走 `hive_ce`）。
  - 保留待确认项：`DetailExtras`、`ReaderSelectionEntry`、`HomeMediaCard` 等「只在自家文件内使用」的公开声明，是否降为私有涉及公开 API，未动。
- 测试：`flutter analyze` 无问题；新增 5 条用例（`dailyIn` 三种口径 + 日期标签 + 报告页「每日阅读」7 行）；全量 `flutter test` 通过数 1485 → 1490，失败 15 条与基线 `9d20ecb` 完全一致（阅读器系统栏/批注/段评等既有问题，与本次无关）。
- APK：签名、对齐校验通过；SHA-256 `0299fdc928591880208d8e0d7fb7cc1d1d782996a213bbf3973abf9e44cbd102`；38,524,658 字节。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 「我的」页只剩 阅读热力图 / 我的笔记 / 最近阅读 / 阅读排行，无「每日记录」「最近封面」；
  - 热力图卡片副标题「最近 16 周 · 点击查看每日阅读」；
  - 报告页「每日阅读」周档 5 行（周一→今天），时长完整显示，进度条以周内最高一天为满格；
  - 深色模式下卡片底色/文字/进度条随主题切换，无白块。

# 三十、字数口径 v2：按停留时长估算 + 本章封顶

- 版本：`1.0.129 (134)` 覆盖安装。
- 问题：累计阅读字数明显虚高（真实阅读 14 小时，却显示 51.4 万字）。根因是旧口径：进入一章就把**整章排版后的正文字数**一次性计入（`_countedChapters` 只防重复计数）。于是「目录直接跳到最后一章、一个字没看」也会 +几万字，「一路狂滑划过几十章」也会整章整章地加。
- 新口径（`lib/services/reading_stats_store.dart`）：
  - 字数 = **停留秒数 × 5 字/秒**（≈300 字/分钟），再用**本章正文长度封顶**；
  - `estimateReadCharacters({seconds, chapterChars, alreadyCounted})`：本章剩余可计字数不足时按剩余计，已计入的部分不重复；
  - 单次结算最多认 **120 秒**：把页面挂在那儿不动（去接水、锁屏前）不会持续涨字数。
- 阅读器侧（`lib/pages/reader_page.dart`）：
  - 删除 `_countedChapters` 与「打开整章即整章计数」，改为 `_chapterCharsTotal / _chapterCharsCounted`；
  - `_settleReadTime()` 结算时长的同时折算字数（与阅读时长用同一套「事件间隔」语义）；
  - `_resetChapterChars()` 在新章排版后重设预算；`_switchScrollSegment()` 先结算旧章再重置，避免把旧章停留时间算到新章头上；`_load()` 开头也先结算。
- 历史数据迁移（`lib/main.dart` → `ReadingStatsStore.migrateToTimeEstimate`）：
  - schema 版本位 `reading_stats_schema` = 2，只在首次升级时跑一次；
  - 用已有时长表 `readTimeSnapshot()` 逐日重算字数（`秒 × 5`），找不到时长的历史日期留 **1 字占位**，只为保住连续打卡天数；
  - 迁移失败不影响启动，下次启动重试。
- 测试：`flutter analyze` 无问题；`reading_stats_test.dart` 新增 5 组用例（几乎不停留≈0、300 字/分钟、不超过本章长度、已计入不重复、迁移只跑一次），相关 6 个测试文件 45 项通过。
- APK：正式签名、ABI、原生库及 ZIP/ELF 16 KiB 对齐校验通过；SHA-256 `ea839dc3f1e716661a2b091c3f56c10af2a4c73c32000e26b3146f5968aef146`；38,524,657 字节。
- 真机（Redmi K20 Pro `b2f8e975`）核验：累计字数 **51.4 万字 → 25.3 万字**（842 分钟 × 300 字 ≈ 25.2 万字，与迁移公式一致），连续打卡仍为 5 天。
- 真机行为核验（逐项对照用户两条诉求）：
  - 迁移：累计字数 51.4 万字 → 25.3 万字（842 分钟 × 300 字 ≈ 25.2 万字，与公式一致），连续打卡仍为 5 天。
  - 跳到最后一章：目录选第 131 章（全书 99.5%）停留 ~3 秒即退出，字数停在 25.3 万字不动（旧口径会 +数千字）。
  - 狂滑不看：正文连续快滑 40 次冲到底、再往回快滑 40 次跨章，字数仍为 25.3 万字（旧口径跨 2 章即 +约 9 千字）。
  - 正常阅读对照组：同一章内正常停留阅读约 4 分钟，字数 25.3 → 25.5 万字（≈1200 字，符合 300 字/分钟），阅读时长同步 14h5 → 14h9。

# 三十一、v30 批次：我的页三处重复收敛

- 版本：`1.0.129 (134)` 覆盖安装。
- 背景：上一批收尾时留下的三项「疑似重复」由实现方自行判断后处理，均属低风险的入口/展示收敛，不动数据与公开 API。
- 一、笔记入口 3 处 → 2 处：
  - 删掉「我的」页快捷栏里的「笔记」磁贴（`lib/pages/mine_page.dart`），连同不再需要的 `NotesPage` import；
  - 保留底部导航「笔记」（主入口）与统计页「我的笔记」卡（带批注条数，位置在热力图下方），两处职责不同，不构成重复；
  - 快捷栏因此变成 章节缓存 / 应用设置 / 关于我们 三格，宽度均衡。
- 二、概览卡指标重叠 → 4 宫格 + 1 行：
  - 六宫格（今日 / 本月 / 总计 / 活跃天数 / 累计字数 / 连续打卡）里，「活跃天数」「连续打卡」同属「读了几天」，和时长、字数混排时六个数字主次不分；
  - 宫格收敛为 今日 / 本月 / 总计 / 累计字数 四项，「活跃 N 天 · 连续打卡 N 天」合成宫格下方一行（`_daysLine`，用 `Wrap` 排布，窄屏 + 1.8 倍字号也不会溢出）。
- 三、封面渲染 2~3 份 → 1 份：
  - 新增 `lib/widgets/book_thumb.dart` 的 `BookThumb`：空链接兜底、加载失败兜底、圆角、按显示尺寸 3 倍解码、统一走 `PosterCache`；
  - `lib/pages/stats_page.dart`「最近阅读」行与 `lib/pages/reading_report_page.dart`「阅读最久」封面改为复用它，删掉各自的私有 `_cover / _BookCover`（连同多余 import）；
  - 书架卡片（带进度角标）、首页故事封面（自绘渐变）视觉与结构都不同，不是重复实现，保持原样；笔记页「按书查看」用的是首页同款 `StoryCover`，也保持。
- 测试：`flutter analyze` 无问题；`stats_page_widget_test.dart` 新增 2 条用例（概览四宫格 + 天数并一行、我的页不再有笔记快捷入口）；全量 `flutter test` 通过数 1490 → 1497，失败 15 条与基线完全一致（阅读器系统栏/批注/段评等既有问题）。
- APK：签名、zipalign、ABI、16 KiB 对齐校验通过；SHA-256 `9e339633e9f07758dc6294262aef9e28c740bfe68fc9514f292446d1f6a872ec`；38,524,659 字节。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 「我的」页快捷栏只剩 章节缓存 / 应用设置 / 关于我们；底部「笔记」与卡片「我的笔记 6 条批注与书摘」仍在；
  - 概览卡 4 宫格 + 底部「活跃 5 天 · 连续打卡 5 天」，无溢出；
  - 「最近阅读」三行封面（含空封面兜底）正常；「我的阅读 → 阅读最久」封面正常显示。

# 三十二、v31 批次：页数与百分比留空档 + 阅读结算的空档上限

- 版本：`1.0.129 (134)` 覆盖安装。
- 一、正文状态行（`lib/widgets/reader/reader_status_bar.dart`）：
  - 原来左下角是一整串 `'$readPage/$bookPages $percent%'`，单个空格让「1781/1965」和「90.6%」粘成一个数；
  - 拆成两个 `Text`（`reader-page-progress` / `reader-page-percent`），中间插一个 `SizedBox`，宽度用 `TextPainter` 实测「空格 + 两个数字」的宽度，换字体或调大系统字号都跟着走；
  - 行高、省略策略、电池块位置不变，状态行高度仍恒定（不引入正文跳动）。
- 二、字数 / 时长结算的空档上限（`lib/services/reading_stats_store.dart` + `lib/pages/reader_page.dart`）：
  - 新增 `kMaxReadingGapSeconds = 120`；
  - `_settleReadTime()` 把「距上次结算的间隔」夹到 120 秒再写时长与字数：翻页/滚动才会触发结算，所以「打开一页不动」本身不涨；但挂机 20 分钟后再滚一下，原先会把整段空档算进阅读时长（字数只受 120 秒封顶的间接约束），现在两者都按 120 秒计；
  - `_accumulateReadCharacters()` 里的 120 秒常量改用同一常量，注释说明真正的上限是本章正文字数。
- 回答「会不会刷字数」：不会。
  - 静止不动没有任何结算事件，字数为 0 增长；
  - 切后台 / 锁屏：`didChangeAppLifecycleState` 里立刻结算并把会话置灰，回前台重新计时，后台时间完全不计；
  - 唯一残留的缝（挂机后滚一下）被这次 120 秒上限封死：单次最多 +600 字，且全章字数封顶后不再增加。
- 测试：`flutter analyze` 无问题；`reader_interface_test` 的「clock and battery」用例改为盯百分比并新增「页数与百分比间距 > 8px」断言；全量 `flutter test` 通过 1497 项，失败 15 条与基线一致。
- APK：签名、zipalign、ABI、16 KiB 对齐校验通过；SHA-256 `82695d06a4b7b0dc86896c5b9f75af4c467b49e42977a5dffac64ba1d0f4462b`；38,524,658 字节。
- 真机（Redmi K20 Pro `b2f8e975`）核验：正文左下角显示「1781/1965　90.6%」，页数与百分比之间约两个数字宽的空档，右下角电量「100%」不受影响。

# 三十三、v32 批次：我的页继续减法（去笔记卡、去书友栏、设置只留右上角）

- 版本：`1.0.129 (134)` 覆盖安装。
- 一、删除「我的笔记」入口卡（`lib/pages/stats_page.dart`）：
  - 连同 `_NotesEntryCard` 组件、`_annotationCount` 字段与其异步计数回填一起删掉（`ReaderAnnotationStore.countAll()` 调用随之移除，页面少一次 Hive 读）；
  - 笔记入口只剩底部导航「笔记」一处。
- 二、设置入口只留右上角（`lib/pages/mine_page.dart`）：
  - 删掉快捷栏里的「应用设置」磁贴，以及「书友」卡内右侧的「设置」胶囊按钮；
  - 现在设置只有右上角图标（日夜切换按钮的右边），与页面其他地方不再重复。
- 三、删除「书友」名片（`lib/pages/mine_page.dart`）：
  - 整个卡片（头像 + 书友 + 副标题 + 设置胶囊）移除，页面上方只剩两格快捷入口（章节缓存 / 关于我们）与「阅读与视听统计」标题；
  - `_buildProfileHeader` 同时去掉不再需要的 `ColorScheme` 参数，`build` 里也不再取 `theme/scheme`。
- 测试：`flutter analyze` 无问题；`stats_page_widget_test` 的我的页用例改写为「只留右上角设置入口、不含书友卡与笔记卡」，新增对 `应用设置 / 我的笔记 / 书友` 均不存在的断言；全量 `flutter test` 通过 1497 项，失败 15 条与基线一致。
- APK：签名、zipalign、ABI、16 KiB 对齐校验通过；SHA-256 `dde47f02ce7899fc4c51ae8b672da68e50972bc9ce453a7515846c0685f99bd9`。
- 真机（Redmi K20 Pro `b2f8e975`）核验：
  - 「我的」页顶部无书友卡，两格快捷入口（章节缓存 / 关于我们）居中铺满；
  - 热力图下方直接是「最近阅读」，没有「我的笔记」卡；
  - 右上角只有 日夜切换 + 设置 两个按钮，点设置正常进入设置页。

# 三十四、v33 批次：代码精简（行为等价，不改接口）

- 版本：`1.0.129 (134)` 覆盖安装；本批只做死代码与重复消除，不改 UI、数据口径和任何公开签名。
- 总规模：8 个提交，27 个文件，+298 / −2829（净 −2531 行）。
- 一、死文件（`910d2fb`）：删除 `lib/pages/listen_mode_page.dart`、`lib/services/book_open_preferences.dart`、`lib/services/player_load_diagnostics.dart`、`lib/widgets/home/home_spotlight.dart`、`lib/widgets/home/home_tab_bar.dart` 及 4 个只测它们的用例；依据是 lib + test 全项目零 import、零符号引用。
- 二、主题配色去重（`edd02ab`）：墨水屏 `ColorScheme` 抽成 `app_theme.dart` 的 `einkColorScheme`，`reader_theme.dart` 改为直接引用，删掉第二份 26 行配色表。
- 三、短剧遗留组件（`69b72b9`）：删除 `detail_sections.dart` 的 `DetailCastRow` 与 3 个只服务它的私有组件（−161 行），全项目已无调用。
- 四、书名清洗去重（`c9fa73d`）：`splitTitleAndAuthor` 的两份 44 行副本收敛到 `lib/services/book_title_cleaner.dart`；`imported_book_store.dart` 用 `export` 保持原导入路径可用，调用方不用改。
- 五、听书菜单去重（`cddee4b`）：有声书字幕与系统朗读的「从本句听」弹层逐行相同，抽成 `_confirmListenFromHere`；两条路径原有的 `mounted` 检查差异按原样保留。
- 六、批注 / 设置页结构（`44e1bc3`）：
  - `reader_page.dart` 两处 13 行 `ReaderInlineNote` 构造抽成 `_inlineNoteOf`；
  - 设置首页与分类页的 Scaffold + AppBar + 卡片 + 分隔线抽成 `SettingsScaffold`（`children` 由页面提供），两页各少一层 `for/if` 嵌套，渲染树与原来一致；
  - `BookComment.relativeTime` 删掉 `seconds < 0` 分支——它与紧随其后的 `seconds < 60` 都返回「刚刚」，属冗余判断；
  - 删除零引用的 `appSeedColor`（实际用色在各处已有独立常量）。
- 七、死成员（`4d00667` / `31a9a67`）：
  - 删除无人 import 的 `lib/services/player_preferences.dart`（57 行，播放偏好已迁到 `audio_preferences.dart`）；
  - 删除 `FanqieHistoryImportService.loginAndFetch`（67 行，导入页只走 `pickFile`）、`EpisodeSource.withVariant`、`ShelfDesign.labelControl`、`BookDetail.hasMeta`；
  - `ReadingCapsuleHost` 的 `_readers` 计数与 `readerActive` 无人读取（胶囊已改为常驻完整形态），一并移除；`enterReader / exitReader` 的通知行为保持不变。
- 明确跳过（行为不等价或属产品决策）：
  - `chapter_text_formatter.dart` 与 `imported_book_store.dart` 的块标签集合差一个 `pre`，不合并；
  - 各 model 里的 `_int`：一份带 `isFinite` 保护、一份带 `fallback` 参数，语义不同，不合并；
  - `book_comment.dart` / `playlet_comment.dart` 的 payload 解包相似但字段与后续分支不同，不合并；
  - `detail_snapshot_cache` / `chapter_cache_store` 的 `Chapter` 解析：后者少 4 个字段，不合并；
  - `ApiClient` 的 `playlet*` / `rankBoard` / `commentsByIds` / `shareShortUrl` / `channelTabs` 等零调用方法：属于保留的后端能力面，标记「待确认」，本轮不删；
  - 各 model 里的 `_string` 逐字相同（7 份），合并需要给 7 个文件加共享 import，净行数几乎不变，按「低收益」暂不合并；
  - 两个导出器的渐变画布 8 行重复：宽高与底色常量各自私有，抽公共层收益低于耦合成本，未动。
- 验证：
  - `flutter analyze` 全项目 0 问题；
  - 全量 `flutter test`：通过 1470、跳过 10、失败 15，失败集合与本轮开工前基线完全一致（`comprehensive_ui_loading`×3、`reader_annotation`×2、`reader_paragraph_actions`×5、`reader_system_bars`×5），无新增失败；
  - APK：签名 / zipalign / ABI / 16 KiB 对齐校验通过；SHA-256 `c3a7abc81dfd16c2127e3a7eac91d4cfe5e382ed1c967b5f5ccd24134d2a7801`，38,524,656 字节；
  - 真机（Redmi K20 Pro `b2f8e975`）覆盖安装并启动，首页、书架、笔记、我的均正常渲染。

# 三十五、v34 批次：用例与改版对齐，全量测试归零

- 版本：`1.0.129 (134)` 覆盖安装；本批只改用例与注释，不改产品行为。
- 背景：上一轮记录「失败 15 条与基线一致」，逐条核对后确认全部是功能改版后没同步的旧断言，不是新回归。按现行为修正后，全量测试从 15 失败变为 0 失败。
- 一、系统栏（`test/reader_system_bars_test.dart`）：
  - 旧用例「状态栏常显：阅读器全程不再请求沉浸模式」对应中间方案，现产品是「工具栏收起→沉浸，展开→edge-to-edge」；
  - 改写为「工具栏收起时沉浸，展开时恢复系统栏」：用 `SystemChannels.platform` 记录 `SystemChrome.setEnabledSystemUIMode`，断言进入正文为 `immersiveSticky`、点中间展开为 `edgeToEdge` 且原生 `setImmersive(false)`、再点收起回到沉浸、切后台恢复后仍沉浸、被其他页盖住恢复、退出阅读页恢复；
  - 段评弹层用例改为「打开时恢复系统栏，关闭后重新沉浸」；
  - 4 条安全区用例原先点「收起阅读菜单」tooltip，该按钮已按需求换成「加入书架」，改为再次点击正文收起菜单。
- 二、批注插入位置（`test/reader_annotation_test.dart`）：批注已按需求插在「批注行的下一行」，段落会在行尾切成前后两块；断言改为「前块是原文前缀 + 后块是剩余正文」，定位用例额外校验字符与原文一一对应。
- 三、段落操作（`test/reader_paragraph_actions_test.dart`）：听书按钮按需求改为常显，4 条原本断言「拖动选区后不显示」的用例改为 `findsOneWidget`；标签已改为「从本段开始听书」，文案断言同步。
- 四、详情下载（`test/comprehensive_ui_loading_test.dart`）：下载入口已改成 AppBar 图标按钮（与加入书架互换），改按 `detail_download_button` 点击。
- 五、注释纠偏：`reader_paragraph_menu.dart` 与 `reader_text_selection.dart` 里「拖动选区去掉从本段听」的旧注释改成当前行为。
- 验证：
  - `flutter analyze` 0 问题；
  - 全量 `flutter test`：通过 1485、跳过 10、失败 0；
  - APK：签名 / zipalign / ABI / 16 KiB 对齐校验通过；SHA-256 `ab549937230946903db5bdffe0491be81cf1de14622acbdd0cb016ed8c77bb7f`，38,524,657 字节；
  - 真机（`b2f8e975`）覆盖安装：设置首页（单卡片 + 分隔线）、分类页「外观」渲染正常，深色模式与墨水屏开关位置不变。
  - 真机复核正文沉浸态：工具栏收起时状态栏与手势导航隐藏，点中间展开后两者恢复，再收起重新隐藏；两次截图中高亮段落像素行号完全一致（759…1431），确认工具栏是覆盖而非挤压正文；退出阅读页后系统栏恢复。

# 三十六、v1.0.129 基准版本（2026-10-23）

- 定位：以 `1.0.129+134` 当前实现作为后续开发的基准版本；`master` 历史保留 v33 精简批次与 v34 用例对齐批次。
- 代码精简收尾决策（按「低风险优先、不改公开 API」执行）：
  - `ApiClient` 的 `playlet*` / `rankBoard` / `commentsByIds` / `shareShortUrl` / `channelTabs` 等零调用方法保留：它们是后端能力面对应的方法，删除会改变公开 API，收益仅为行数；
  - 各 model 的 `_string` 虽然逐字相同，但合并需要给 8 个文件增加共享 import，净行数几乎不变且增加耦合，保留现状；
  - 以上两项均不构成功能问题，不再改动。
- 验证基线：
  - `flutter analyze`：0 问题；
  - 全量 `flutter test`：通过 1485、跳过 10、失败 0；
  - 真机（Redmi K20 Pro `b2f8e975`）：正文沉浸态、工具栏覆盖不挤压正文、退出恢复系统栏均通过；
  - Release APK：38,524,657 字节，SHA-256 `ab549937230946903db5bdffe0491be81cf1de14622acbdd0cb016ed8c77bb7f`。
- 备份产物（桌面）：
  - `fqapp-src-1.0.129-20261023.bundle`：含全部提交与标签的 git bundle；
  - `fqapp-src-1.0.129-20261023.tar.gz`：HEAD 源码快照；
  - `qingqie-1.0.129-release.apk`：基准安装包。
- GitHub 远端：`https://github.com/fangyuzhang/qingqie-reader-app`（私有），`master` 已同步，标签与 Release `baseline-1.0.129-20261023` 附基准 APK；旧仓库 `fangyuzhang/qingqie-reader` 未改动。

# 三十七、v35 批次：UI 可访问性与首页 / 我的 交互收口（2026-10-23）

- 版本：仍为 `1.0.129 (134)`。本批只动视觉层与交互入口，不新增依赖、不改状态流转，因此不升版本号。
- 起点：按 apple-design-skill（只取通用原则，忽略 iOS 专属惯例）对 `lib/` 做一次视觉层审查，落到 Android / Flutter 语境后集中修复；数值以 Material 为准（命中区 ≥ 48dp，间距取 4 的倍数）。

## 一、无障碍：小字号对比度

先算后改。原值全部低于 WCAG AA 的小字号门槛 4.5:1，改后留有余量且不改变品牌色的填充用法。

| 位置 | 颜色 | 对比度 | 文件 |
| --- | --- | --- | --- |
| 全局次要文字（浅色） | `#6C7A73` → `#5E6B64` | 4.33:1 → **5.37:1**（canvas `#FAFBF6`） | `lib/services/app_theme.dart` |
| 首页次要文字 | `#6C7A73` → `#5E6B64` | 同上，与全局 token 对齐 | `lib/widgets/home/home_design.dart` |
| 首页强调小字 | `accentStrong #1F8A72` → `#176B58` | 4.25:1 → **6.16:1**（canvas）/ 5.69:1（soft `#EEF3EC`） | `lib/widgets/home/home_design.dart` |
| 阅读器强调色（浅色系） | `#9B6743` → `#8A5B39` | 3.78:1 → 5.49 / 4.97 / **4.59:1**（米白 / 青绿 / 纸张） | `lib/widgets/reader/reader_theme.dart` |
| 阅读器辅助文字 | 正文色 60% → 80% alpha | 4.01 / 3.64 / 3.08:1 → **7.51 / 6.47 / 5.02:1** | `lib/widgets/reader/reader_theme.dart` |
| 状态行字号 | 10sp → **11sp**（行高同步固定） | 小字号更易读，行高固定避免抖动 | `lib/widgets/reader/reader_status_bar.dart` |
| 书架进度角标 | 9sp → **11sp**，深青渐变 → 深珊瑚渐变 | 角标在封面上不再被背景吞掉 | `lib/widgets/bookshelf_card.dart` |
| 封面信息 chip | 9sp → **11sp** | 与角标同一档 | `lib/widgets/cover_tag_chip.dart`、`lib/widgets/home/home_media_card.dart` |

说明：填充色仍用原 `accent`，只把小字前景换成更深的 `accentText`，品牌观感不变。

## 二、命中区补到 48dp

视觉尺寸刻意保持不变，只扩可点范围，避免"看起来变小 / 变大"的连锁改版：

- `lib/pages/library_page.dart`：分组 chip（27dp 胶囊 / 48dp 命中区）、tab 行（~35dp 文字+指示条 / 48dp）、版式分段（原 40×30 → 40×48，图标仍 17dp）。
- `lib/pages/notes_page.dart`：批注类型筛选行 40dp → 48dp（`ChoiceChip` 在 `padded` 下自带 48dp）。
- `lib/pages/stats_page.dart`：日期区域整体可点，命中区随行高撑开。

## 三、首页

- **分类卡文案**：`精选 N 本` → `精选书单 · 查看全部`。原因是「全部」页会继续从书城追加书目（真机进入「古典名著」显示"已载入 40 本"），写死本地数量必然误导。
- **横向书架滑到底继续滑 = 查看全部**：新增 `_CategoryRail`，`NotificationListener<ScrollNotification>` 在到达末端后累计 `overscroll`，约 **72dp** 触发一次 `HapticFeedback.selectionClick()` 并打开该分类「全部」。阈值下限防止正常甩动误触，上限防止"滑不动"的错觉。
- **删除滚动悬浮搜索按钮**：移除 `_searchFabVisible`、`_onHomeScroll`、`_searchFab` 与包裹的 `NotificationListener`，搜索只保留固定顶栏入口。少一层滚动监听，滚动帧更稳。

## 四、我的 / 统计 / 设置

- `lib/pages/stats_page.dart`：日期旁补「📅 选择日期 ⌄」胶囊，整块可点；大字号下改用 `Wrap`，日期与按钮不再互相挤压；`DatePickerDialog` 可正常打开。
- `lib/pages/notes_page.dart`：时间轴日期 `maxLines: 1`，不再折成两行把条目顶歪。
- `lib/pages/settings_page.dart`：主题当前值改用 `muted` token；服务状态改用 `ColorScheme` 语义色，不再写死绿/红。

## 五、测试

- `test/home_page_test.dart`：新增文案断言（`精选书单 · 查看全部`）、横向滑到末端跳转「全部」、下滑后**不出现**浮动搜索按钮。
- `test/stats_page_widget_test.dart`：新增日期按钮可见性与 `DatePickerDialog` 打开断言。
- 结果：`flutter analyze` 0 问题；全量 `flutter test` **通过 1488、跳过 10、失败 0**（较 v34 的 1485 增加 3 条，均为本轮新增用例）。

## 六、APK 与真机

- Release APK：**38,524,655 字节**，SHA-256 `130b302f6aa8310974c19b090053383189d9d273692bb75182b013b70dd31041`。
- `scripts/verify_android_apk.py` 全项 passed：zip 条目 / Native 库 / ELF 16 KiB / zip 16 KiB / 签名 / 清单元数据 / APK 未被改动；报告 `build/apk-verification/wsl-native-v35/report.json`。
- 清单核对：`com.fqapp.fqapp`、`1.0.129 (134)`、`minSdk 24`、`targetSdk 36`、6 个 `arm64-v8a` 原生库。
- 真机（Redmi K20 Pro `b2f8e975`）覆盖安装复核：
  - 首页下滑不再出现浮动搜索按钮；
  - 横向书架滑到「古典名著」末端继续右滑，进入全部页并显示"已载入 40 本"；
  - 我的页日期胶囊可点，日期弹层正常，选择后统计范围刷新；
  - 笔记时间轴日期单行显示，条目不再错位。

## 七、本批未做（有意留下）

- 日期选择器文案仍为英文，需要引入 `flutter_localizations` 并给 `MaterialApp` 配 locale，属于新增依赖，未在本批处理。
- 墨水屏背景下仍有 93 处直接引用 `HomePalette.accent / highlight`，替换为语义色属中风险改动，未全量执行。
- 阅读器批注块内 3 个 16dp 图标按钮热区不足 48dp，但其宽度参与分页折算，改动会移动分页点，暂缓。

---

# 三十八、v36 / v37 批次：笔记交互重构（多角标 + 拖拽标签）

## 38.1 交互减法

| 位置 | 改动 |
| --- | --- |
| 笔记页顶部 | 删除「筛选」按钮、筛选面板与「时间 / 分类 / 类型 / 标签」二级按钮；顶部只保留视图切换 + 一行快捷筛选 |
| 类型 chip | 点「疑问 / 反驳 / 感悟 / 待查证 / 自定义」只做筛选切换；再点同一项即取消，不再弹出「类型 X / 清除」 |
| 按书查看 | 选中一本书后留在本视图，用顶部范围条（返回 + 书名 + 条数）返回书籍网格；不再自动跳到时间线，也不再出现「书名 / 清除」两个按钮 |

## 38.2 一条笔记多个角标

`ReaderAnnotation` 新增 `extraMarkers`，`markerBadges` 统一输出「主标记 + 额外标记」并去重；旧数据没有 `extraMarkers` 时自动回退为单角标。筛选口径改为「任一角标命中」（`noteHasMarker`），一条笔记可以同时是「疑问 + 待查证」。

## 38.3 「全部类型」= 批注类型 + 自由标签

- 顶部同一行按用户顺序列出所有批注类型与所有自由标签，类型用彩色圆点、标签用 `#` 区分。
- 点类型 = 单选筛选；点标签 = 多选筛选（多个标签之间为 OR），再点取消。
- 长按任意一枚拖到另一枚后面即可换序；顺序持久化在 `ReaderMarkerTypeStore`（`type:<文案>` / `tag:<文案>`，旧的无前缀数据加载时自动补 `type:`）。
- 笔记卡片上的多个角标按同一套顺序混排，超过 3 枚折成 `+N`。

## 38.4 拖拽打标

| 手势 | 行为 |
| --- | --- |
| 长按「全部类型」里的标签 → 拖到笔记 | 打标；原位置留空，松手后弹性重生（复制语义，来源笔记不受影响） |
| 长按笔记上的角标 → 拖到另一条笔记 | 移动；目标已有同名角标时整次拖动视为无操作，不会误删来源 |
| 长按笔记上的角标 → 拖到空白处松手 | 取消该角标 / 标签 |
| 拖动经过笔记卡片 | 出现磁力虚影（0.8 → 1，`easeOutBack`），提示松手后的落点 |
| 拿起标签 | 反馈层弹性放大 1.12，提示可移动 |

细节：`DragTarget` 接受拖回自身，避免「原地松手」被当成丢到空白处而误删；拖拽结束统一清空悬停虚影。

## 38.5 文件

- `lib/pages/notes_page.dart`：删除筛选面板与摘要条，新增统一 `_paletteEntries` / `_badgesOf` / `_reorderTag` / `_toggleType` / `_clearHover` 与笔记落点。
- `lib/widgets/notes/note_tag_drag.dart`（新增）：`NoteTagDrag`、`PaletteTagChip`、`NoteBadgeChip`、`NoteTagGhost`、标签稳定配色。
- `lib/services/reader_annotation_store.dart`：`extraMarkers`、`markerBadges`、`updateTags` / `updateMarkerTags` / `normalizeMarkerTypes`。
- `lib/services/reader_marker_type_store.dart`：统一顺序 `order`（`type:` / `tag:`）与旧数据迁移。
- `lib/services/note_timeline.dart`：多角标筛选。

## 38.6 验证

- `flutter analyze`：0 问题。
- 全量 `flutter test`：**1501 通过 / 10 跳过 / 0 失败**（新增 `reader_annotation_markers_test.dart` 4 条；`notes_page_test.dart` 增至 13 条，覆盖双击取消、多角标、按书查看不跳转、拖类型打标、拖标签打标、跨笔记移动、跨类型换序、拖到空白取消）。
- Release APK：**38,459,051 字节**，SHA-256 `b93ad85d7d9cddff5b36ab902f439100359e1e61c78d4c6f05e2601e47c13896`（`/mnt/d/APP/agent/apk/fqapp-v37.apk`）。
- 真机（Redmi K20 Pro `b2f8e975`）覆盖安装复核：类型与标签同排显示；点标签 A 后书籍网格只剩含该标签的书；「按书查看」选中《西游记》后停留本视图并显示返回条。

## 38.7 已知边界

- 新建自由标签仍走笔记编辑弹层（`initialTags` / `knownTags`），本批没有新增「在筛选行直接输入新标签」的入口。
- 标签颜色由文案稳定派生（浅色/深色各一组），不支持用户单独改色。
- 拖拽在真机上依赖长按 500ms；快速滑动只会滚动这一行，不会误触发打标。

---

## 39.1 笔记卡片：书名固定、标签独占一行

- 标题行只放**书名 + 更多菜单**，时间/章节另起一行，标签再另起一行。
- 标签不再截断成「前 3 个 + N」，全部平铺；增删标签时只会让标签行自身换行，书名与时间不会跟着上下跑。
- 卡片悬停（拖标签经过）时描边加粗并带同色柔光，提示这里是可落点。

## 39.2 类型与标签都可以多选

- 「全部类型」里的批注类型、自由标签都改成**多选**：点一次加入、再点一次取消，不再单选。
- 同一维度内取并集（选中「疑问 + 反驳」＝显示任一命中的笔记），与标签、书籍、分类、时间之间仍是交集。
- 模型层把 `NoteTimelineFilters.markerKey`（单个）换成 `markerKeys`（集合），空集代表不过滤；按书查看同样透传该集合，不会因为切视图丢筛选。

## 39.3 「全部类型」的手机式挤位排序

- 拿起一枚标签时记下整行每枚标签的**左边界与宽度**（含 6dp 间距），按「去掉自己 + 插入到落点」重排一遍，算出每枚标签的目标左边界。
- 被跨过的标签横向让位、原位空位同步挪到插入点，形成手机桌面那种「挤进去」的效果；落点判定用按下时的中心坐标，标签被挤动不会导致来回抖。
- 松手按落点写回 `ReaderMarkerTypeStore.order`，原位置弹性重生（0.55 → 1，`elasticOut`）。
- 位移只用 `Matrix4.translationValues`，不改变布局尺寸，因此拖动过程中整行高度不变、其他标签不会上下跳。

## 39.4 拖回自己卡片的吸附提示

- 拖动中的角标本体会被隐藏，此前「拖回自己」因为卡片上已经有同名角标，虚影分支被跳过 → 完全没有反馈。
- 现在 `NoteBadgeChip` 接收 `highlighted`：命中时原位保留**半透明角标 + 强调色吸附环**，尺寸不变（吸附环画在 `Stack` 的 `Positioned` 层里），松手是无操作、不会误删。
- 目标卡片同时高亮描边，双重提示「松手会落在这里」。

## 39.5 文件

- `lib/pages/notes_page.dart`：`_paletteSlots` 几何快照、`_paletteTargetLefts` 挤位计算、`_paletteShiftFor` 重写；`_TimelineNoteRow` 标题/时间/标签三行结构与 `hovered` 描边；`highlighted` 透传。
- `lib/widgets/notes/note_tag_drag.dart`：`NoteBadgeChip.highlighted` 与半透明占位 + 吸附环。
- `lib/services/note_timeline.dart`：`markerKeys` 多选并集。
- `test/notes_page_test.dart`、`test/note_timeline_test.dart`：多选并集、书名固定、拖回自身吸附、挤位只横向让位等用例。

## 39.6 验证

- `flutter analyze`：0 问题。
- 全量 `flutter test`：**1507 通过 / 10 跳过 / 0 失败**。
- Release APK：38,524,599 字节，SHA-256 `32abc721675f235304f2e3248cd2ef27ae4ecb059d0653effaab42d28322a7c7`（`/mnt/d/APP/agent/apk/fqapp-v39.apk`，版本 1.0.130+135）。
- 真机（Redmi K20 Pro `b2f8e975`）：同时选中「反驳 + 疑问」两枚类型保持选中态；长按「反驳」右拖，途中「疑问 / 待查证」依次左移、空位跟到插入点且整行不平移，松手后顺序变为「疑问 / 待查证 / 反驳」并持久化；把角标 `#A` 拖回本条笔记时，原位出现半透明 `#A` + 强调色吸附环、卡片描边高亮。

