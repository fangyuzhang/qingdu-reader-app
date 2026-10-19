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
