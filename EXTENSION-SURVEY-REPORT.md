# 轻读（fqapp）扩展点勘察报告 —— 第 1 组交付物

> 生成时间：2026-10-25（UTC+8）
> 勘察方式：3 个并行只读勘察 agent（阅读链路 / 批注体系 / 导入解析管线）+ 人工核验护栏、依赖与路由；未改动任何业务代码。
> 基线：master @ de6f5c0 区间（v1.0.131+136），工作树含未提交的 v56 磁贴重叠修复（home_page.dart / curated_book_cover.dart / home_page_test.dart）。
> 本报告服务于「PDF 阅读 + 手写墨迹批注」七组任务规划，全部结论以代码为准；与任务书（提示词）描述不符处已在 §0 显式声明。

---

## 0. 与任务书前提的差异声明（后续各组必读）

任务书描述的仓库形态与本仓库代码存在多处不符。**后续各组动工前先看本表**，路径与措辞一律以右侧「代码事实」为准。

| # | 任务书前提 | 代码事实 | 对后续任务的影响 |
| --- | --- | --- | --- |
| 1 | 仓库 github.com/fangyuzhang/qingqie-reader | 实际远端 github.com/fangyuzhang/qingdu-reader-app（旧地址 qingqie-reader-app 自动重定向，同一项目） | 无实质影响 |
| 2 | 目录 `lib/core`、`lib/data/{model,local,remote,parser,file,repository}`、`lib/feature/{bookshelf,reader,source,search,settings}` | **均不存在**。实际为 `lib/{main.dart, models/, pages/, services/, src/, widgets/}`。`lib/feature/` 曾因玻璃主题短暂存在，v54 已整体删除 | 任务书里所有 `lib/data/...`、`lib/feature/...` 路径按下文本报告 §5 映射到实际路径 |
| 3 | 分层 UI(Widget) → ViewModel → Repository → DataSource | **无 ViewModel 层、无 Repository 抽象**。实际：pages（StatefulWidget，状态在 State）→ services（具体类 + `static final instance` 单例）→ 加密 Hive / SharedPreferences / Rust loopback。AGENTS.md 规定业务层访问后端一律经 `lib/services/api_client.dart` 的 `_get` | 第 3 组的 `InkAnnotationRepository`、第 4 组的 `PdfReadingRepository` 落地形态 = services 目录下的 store 单例（见 §4） |
| 4 | 批注存储「哪张表、哪个 DAO」「遵循现有 sqflite 建表与迁移风格」 | **全仓库零 sqflite**。存储 = hive_ce 加密盒（AES-256，密钥在 flutter_secure_storage/Keystore）+ 盒名 `_v1` 版本化 + `toMap/fromMap` 手工序列化（无 TypeAdapter） | 第 3 组「建表语句/DAO」应改写为「新 Hive 盒 + fromMap 容错」，模板照抄 `reader_annotation_store.dart` |
| 5 | 已有「书源引擎」 | 无 Legado 式可配置书源。上游是固定番茄协议：进程内 Rust 核心 `fqapi_core`（FRB 2.13.0）+ `127.0.0.1:8080` loopback | 对 PDF 计划无影响；PDF 不经过该链路 |
| 6 | 已支持 TXT/EPUB 本地导入、双模式、文本批注 | ✓ 全部属实（`imported_book_store.dart`、`ReaderPageMode{paged,scroll}`、`ReaderAnnotation/ReaderRangeUnderline`） | — |
| 7 | 目标设备 华为 MatePad 11 + M-Pencil 3 | 当前开发机只连 **Redmi K20 Pro（b2f8e975，无手写笔）** | 第 2/5/6 组的真机实测结论必须等 MatePad 在场；K20 Pro 只能验证代码可运行、手指触摸 kind 区分 |
| 8 | （未提及） | **全应用锁竖屏**（README 交互约定 #8，main.dart + MainActivity 双保险） | 平板手写通常期待横屏。是否为批注模式解锁竖屏锁属「改约定」，需用户拍板；不改则竖屏书写也可用 |
| 9 | PDF 候选包 pdf_master / advanced_pdf_viewer | pub.dev 无法确认这两个包存在。真实可行候选见 §4.3（推荐 pdfrx） | 第 4 组选型以 §4.3 为起点 |
| 10 | GPL-3.0 | ✓ LICENSE 为 GPL-3.0 全文 | 新增第三方包必须许可证兼容（§4.3 已核验 pdfrx） |

---

## 1. 阅读器（reader）完整调用链

### 1.1 ReaderPage 与入口

`ReaderPage` 定义于 `lib/pages/reader_page.dart:67`（State 类 `_ReaderPageState` :134）。参数面（:72–104）：`bookId / title / cover / chapters / startIndex / localOnly / chapterLoader(ChapterTextLoader?) / readerStore / chapterCache / readerDevice / imageProviderFactory / ideasLoader / commentResolver / underlineStore / annotationStore / startTextOffset / ageRating`。

**分流契约（对 PDF 接入最重要）**：没有显式「来源标记」字段——`chapterLoader != null` 即「调用方自带本地数据源」，`localOnly` 跟随它（`local_book_detail_page.dart:91`）。ReaderPage 全链路（正文 :2139–2152、段评 :1988–1994、缓存刷新 :2165）据此自动转离线。

8 个实例化点：

| 路径 | 位置 | 关键传参 |
| --- | --- | --- |
| 书城在线书（主路径） | `lib/pages/detail_page.dart:1213` | `chapters/readerStore/chapterCache`，无 loader（联网取正文） |
| 离线缓存直读 | `lib/pages/cached_book_reader.dart:44`（调用方 detail_page.dart:1260） | `chapterCache` 注入即离线，失败返回 false 回退联网 |
| 本地导入书 | `lib/pages/local_book_detail_page.dart:85` | `localOnly: chapterLoader != null`、`chapterLoader` |
| 笔记页「定位原文」 | `lib/pages/notes_page.dart:1474` | `chapterLoader` + `startTextOffset`（**字符偏移直跳的现成先例**） |
| 系统朗读接管 | `lib/pages/audio_page.dart:774/820/838` | 仅基础参数 |

本地导入书的上游：`library_page.dart:311`（`ImportedBookStore.instance.pickAndImport()` 导入）→ `:375 _openLocalBook` → `LocalBookDetailPage` → ReaderPage。

### 1.2 章节文本获取链（在线书）

```
ReaderPage._chapterText (reader_page.dart:1862)
  → ReadableChapterResolver (services/readable_chapter_resolver.dart，跳过占位章)
  → _loadChapterText (:2287)
      ① 内存 LRU _chapterCache（5 章，:2279）
      ② 加密磁盘缓存 ChapterCacheStore.read(bookId, chapterId)（services/chapter_cache_store.dart，盒 chapter_cache_v1）
      ③ miss → _fetchChapter (:2137) → ApiClient.instance.chapterContent(itemId)（services/api_client.dart:1243）
  → ChapterContent.fromCacheText (services/chapter_text_formatter.dart:156)
```

ApiClient → `backend_transport.dart`（BackendRequest 可取消/去重）→ flutter_rust_bridge `request()`（`lib/src/rust/api.dart:78`，**生成物禁手改**）→ 进程内 Rust `fqapi_core` loopback → 番茄上游。Rust 对书箱/章节**没有专用 FFI 函数**，全部走通用 HTTP 通道。

### 1.3 分页/排版所在层：**全部在 Dart，Rust 零参与**

- 排版引擎：`lib/widgets/reader/reader_chapter_layout.dart`（1547 行）。核心类：`ReaderLayoutSpec`(:18)、`ReaderContentBlock`(:166)、`ReaderPageFragment`(:422)、`ReaderTextPage`(:444)、`ReaderChapterLayout`(:456)。逐段用 `TextPainter` 量高（:742–753），分页算法 `_paginate`(:1028–1076)：逐行累加超过 `spec.pageHeight` 即切页。
- 偏移换算：`pageForOffset`(:628–660) / `scrollForTextOffset`(:656) —— **字符偏移 ↔ 页码的现成换算**。
- reader_page 侧：`_prepareLayout(constraints)`(:2782–2850) 在 LayoutBuilder(:3989) 里构造 spec 并恢复进度。
- 双模式分流：`_buildContent`（:4037 `ReaderPagedView` vs :4071 滚动 ListView）。UI 切换在 `reader_appearance_sheet.dart:328–339`。
- Rust 侧 grep 无任何 pagination/layout 实现（仅两处注释）。

### 1.4 进度与偏好

- 进度：`services/reader_history.dart`（写守卫）→ `LibraryStore`（加密 Hive 盒 `'history'`，key=书 id）。条目结构（reader_page.dart:3044–3073）：`{id, kind, chapterId, episode, position, positionVersion:2, textOffset(章内字符偏移), progress, ...}`，恢复按 `positionVersion` 分版本（:2260–2267）。**PDF 需要新的版本号或页码型记录**。
- 排版偏好：`services/reader_preferences.dart`，SharedPreferences（全局非按书），含 `ReaderPageMode/ReaderThemePreset/ReaderPageTurnStyle`。

### 1.5 lib/widgets/reader/ 清单（16 文件）

`chapter_directory_sheet`(目录弹层)、`reader_appearance_sheet`(排版面板)、`reader_bubble`(段评气泡)、`reader_chapter_layout`(**排版/分页引擎**)、`reader_controls`(底部菜单，localOnly 隐藏在线操作)、`reader_cutout_insets`、`reader_ideas_sheet`、`reader_illustration`、`reader_note_block`(行内批注卡片)、`reader_page_curl`(仿真卷页)、`reader_paged_view`(分页容器)、`reader_paragraph_menu`(长按段落菜单)、`reader_status_bar`、`reader_tap_zone_sheet`(点击区编辑)、`reader_text_selection`(选择系统+**ReaderBlockMarkPainter**)、`reader_theme`(五预设色表)。

---

## 2. 现有文本型批注：模型 / 存储 / 渲染

### 2.1 数据模型

**ReaderAnnotation**（批注/书摘，`lib/services/reader_annotation_store.dart:72–309`）：
`bookId / chapterId / start / end（int）/ text（原文快照）/ thought / type('annot'|'excerpt') / createdAt / bookTitle / chapterTitle / category / tags / markerType / extraMarkers / markStyle / markColorValue`。

**ReaderRangeUnderline**（范围划线，`lib/services/reader_underline_store.dart:109–194`）：`bookId / chapterId / start / end / text / createdAt / style / colorValue`。同盒还存旧形态整段划线 `ReaderUnderline`（paraIndex/blockIndex）。

**锚点本质（第 3/6/7 组的根基）**：
- 锚点 = `(bookId, chapterId, start, end)` 四元组 + 原文 `text` 快照。`start/end` 是**章节「展示文本」的字符偏移**，与 `ReaderRangeUnderline.start`、`ReaderContentBlock.start` 同一坐标系（reader_annotation_store.dart:100–103 注释明示）。
- **无** chapterIndex、**无**上下文指纹、**无**百分比。阅读进度里的 `textOffset` 是另一套体系。
- **在线书与本地导入书同构**：本地书 chapterId 由 `imported_book_store.dart:273` 生成 `'$id:chapter:$index'`，两者共用同一排版坐标空间。

### 2.2 存储机制（零 sqflite，全部加密 Hive）

| 盒名 | 文件:行 | key 结构 | 容量策略 |
| --- | --- | --- | --- |
| `reader_annotations_v1` | reader_annotation_store.dart:318 | `jsonEncode(['a',bookId,chapterId,start,end])` | 5000 条，超限按 createdAt 淘汰 |
| `reader_underlines_v1` | reader_underline_store.dart:206 | 范围：`jsonEncode(['r',bookId,chapterId,start,end])`；整段：4 元组 | 2000 条 |
| `reader_marker_types_v1` | reader_marker_type_store.dart:63 | 固定 key `'types'/'order'` | 24 |

统一模式（**InkAnnotation 存储照抄这套**）：`EncryptedHive.openBox`（加密盒命名 `<name>_enc`）+ `hiveReady` 门闩 + `_opening` 单飞 + `_serialize` 写队列串行化 + `changes: ValueNotifier<int>` 通知 UI；`fromMap` 全字段容错（缺省回默认、非法丢弃返回 null）；结构变更开新 `_vN` 盒。

### 2.3 渲染方式

- 正文划线/荧光笔 = **CustomPainter**（非 TextSpan decoration）：`ReaderBlockMarkPainter`（`lib/widgets/reader/reader_text_selection.dart:518–709`），四线型 `_paintMark`(:572–627)：荧光笔=文字后方圆角矩形 alpha 0.32、实线=1.7px、虚线=5/3.5、波浪=正弦 Path。**几何来自 `TextPainter.getBoxesForSelection` 逐行字形矩形（:548–569）——运行时几何，不落盘**。
- 行内批注块：排版层合成块（`ReaderChapterLayout._insertInlineNotes` :1118–1230，按 start 找行拆段插入、整块落页不切断）→ `ReaderNoteBlock` 卡片。
- 创建链路：长按段落 `_onParagraphLongPress`(reader_page.dart:883) → 选择工具条(:1034) → `_addSelectionUnderline`(:1359)/`_createAnnotation`(:1666) → store 落盘。

---

## 3. TXT/EPUB 解析管线：输出结构 / 字符偏移 / 落盘

全在 `lib/services/imported_book_store.dart`（1060 行，单例 `instance` :149–154）。

### 3.1 解析输出结构

- 分发入口（**PDF 分支加在这**）：公开纯函数 `parseImportedBookBytes({fileName, bytes, decodedText})`（:446–459），按扩展名分发，其他格式抛 `FormatException('仅支持 TXT 和 EPUB 文件')`（:458）。纯函数设计便于直接单测。
- worker isolate：`importBytes` 内 `Isolate.run`（:220–237）统一包裹，结果序列化为纯 Map 回传——**新格式自动获得后台解析**。
- 输出：`ParsedImportedBook{title, author, format, cover?, chapters: List<ParsedBookChapter>}`；`ParsedBookChapter` 仅 `{title, text}`（纯文本，无 itemId/无文件引用）。TXT 按标题正则切章（:461–519）；EPUB 按 spine 顺序抽 xhtml 文本（:522–615，防 zip 炸弹 :890–942）。

### 3.2 落盘（明文私有目录，非 Hive）

`<ApplicationSupport>/imported_books/<id>/`：每章一个 `chapter_00000.txt`（UTF-8）+ `cover.png|jpg|svg` + 清单 `book.json`（staging 目录原子 rename :259–306）。章节 itemId = `'$id:chapter:$index'`（:271–277）。读回 `book(id)`(:314) / `chapterText(bookId, chapterId)`(:363–379)。

### 3.3 章节模型

`Chapter`（`lib/models/media_item.dart:629–713`）：`itemId/title/volumeName/version/wordCount/chapterType/...`。**在线书与本地导入书共用同一个类**（导入书只填 itemId/title/volumeName=''），章节缓存 store 也复用。

### 3.4 文件选择

自研原生插件 `MethodChannel('fqapp/local_books')`（imported_book_store.dart:155）→ `android/app/src/main/.../LocalBookPickerPlugin.kt`（SAF ACTION_OPEN_DOCUMENT，**MIME 白名单 :81–84 不含 application/pdf**，32MB 上限 :133/:180）。pubspec **无 file_picker**。

### 3.5 字符位置现状（第 4/5 组的关键前提）

- **已有**：「字符偏移」概念——批注锚点、进度 textOffset、`pageForOffset` 换算、`textInRange` 取原文。
- **没有**：「字符在页面上的坐标」的持久化结构。运行时可从 `ReaderChapterLayout` + `getBoxesForSelection` 派生（ReaderBlockMarkPainter 正是这么画线的）。PDF 的「页 → 文本块 → 字符位置表」没有现成对应物，需第 4 组新建（渲染引擎自带文本 API，见 §4.3）。

---

## 4. 服务抽象方式与 PdfReadingRepository 落点

### 4.1 现有模式

services 目录 40+ 个服务全部是：**具体类 + `static final X instance = X()` 单例**（如 `ImportedBookStore.instance`、`ApiClient.instance`、`ChapterCacheStore.instance`、`ReaderAnnotationStore` 单例 :317）+ 可选 `changes` ValueNotifier。**没有抽象类/接口、没有依赖注入容器**。Widget 不写 IO（护栏红线），状态走 Hive/SharedPreferences。

### 4.2 「新增 PdfReadingRepository」的正确形态

在本仓库不建 `lib/data/repository/`。按仓库惯例 = services 下一个新 store 单例，两种落地：

- **推荐**：`lib/services/pdf_book_store.dart`（管 PDF 导入/落盘/取页，参照 ImportedBookStore 模板）+ 阅读侧复用 ReaderPage 既有参数面（`localOnly: true` + 自定义 loader / 或新内容视图分支）。任务书要求的接口方法（分页、跳转、进度保存）映射到：分页=固定版式天然有页；跳转=页码；进度=LibraryStore 'history' 盒写 `positionVersion:3`（页码型）记录。
- 若坚持任务书的 interface 形态（save/loadByChapter/delete/updateAnchor，第 3 组）：可定义轻量 `abstract class` 由 store 实现并暴露单例——仓库无先例但不与现有风格冲突。

### 4.3 PDF 渲染选型（供第 4 组定稿，已做初步核验）

| 候选 | 内核 | 字符坐标 | 许可证 | GPL-3.0 兼容 |
| --- | --- | --- | --- | --- |
| **pdfrx / pdfrx_engine（首选）** | PDFium | ✓ `PdfTextPage.getCharBox` 等 PDFium 文本 API | MIT（插件）/ Apache-2.0·BSD（PDFium） | ✓ 兼容 |
| flutter_pdfview | Pdfium(barteksc 封装) | ✗ 无文本 API | MIT | ✓ 但能力不足 |
| pdfx | 系统 PdfRenderer | ✗ 无文本 API | MIT | ✓ 但能力不足 |
| syncfusion_flutter_pdfviewer | 自研 | ✓ | 商业/Community 许可 | ✗ 不兼容，排除 |
| MuPDF 系 | MuPDF | ✓ | AGPL | 规避 |

pdfrx 维护活跃、支持 Android arm64。**第 4 组核验清单**：① `.so` 16KiB 对齐（用 `scripts/check_native_alignment.cjs` 检查）；② 仅 arm64-v8a 约束；③ `PdfTextPage` 坐标系（PDF 用户空间 vs 视口像素）与批注锚点换算。若最终选型无法输出字符坐标——pdfrx 能，此风险已消除；但备选思路：渲染层仅按页存墨迹 + 文本锚点降级为「页码 + 页内归一化坐标」（第 3 组模型已预留）。

### 4.4 PDF 的两条集成路线（第 4 组需择一）

- **路线 A（文本化）**：PDF → 抽文本进 `ParsedImportedBook` → 走现有排版引擎。零新渲染层，但丢失固定版式、无字符页面坐标，**无法满足第 4/5 组要求**（墨迹锚定在原版式上）。仅作为「纯文字阅读 PDF」的廉价附加时考虑。
- **路线 B（固定版式，任务书要求）**：新增 PDF 页视图（渲染原 PDF 页）+ 运行时从渲染引擎取字符位置表 + 独立进度形态。挂载点二选一：
  - **B1（最小侵入，推荐）**：独立 `lib/pages/pdf_reader_page.dart`，复用 `reader_controls/reader_status_bar/reader_theme` 等控件与 LibraryStore 进度盒；完全不动 reader_page.dart 正文路径（护栏友好）。
  - B2：在 `reader_page.dart` `_buildContent`(:4037/4071) 的 paged/scroll 分支前加内容类型分支。共用壳最彻底，但 reader_page.dart 4598 行且正文路径是优化期「零改动」红线区，回归面大。

---

## 5. 施工图：文件清单（新增 / 修改 / 复用）

> 路径全部按仓库实际结构（lib/pages、lib/services、lib/models、lib/widgets/reader）。任务书原路径（lib/feature/...、lib/data/...）不采用。

### 第 2 组：手写笔探测页

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| `lib/pages/stylus_probe_page.dart` | **新增** | 全部调试代码集中此文件（Listener + CustomPainter + 统计面板）；文件头留实测结论注释位 |
| `lib/pages/settings_page.dart` | **修改** | 「服务」分类加一个 SettingsItem（先例：`_logItem()` :380–388，Navigator.push MaterialPageRoute），标注「调试用，发布前移除」 |

### 第 3 组：墨迹批注模型与存储

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| `lib/models/ink_annotation.dart` | **新增** | `InkStroke`（点序列 x/y/pressure/timestamp + 笔宽基准 + 颜色）、`InkAnnotation`（锚点四元组复用 `(bookId, chapterId, start, end)` + 新增上下文指纹/归一化坐标/pageWidth/pageHeight/layoutVersion）。不可变，与现有 model 风格一致 |
| `lib/services/ink_annotation_store.dart` | **新增** | **Repository 本体**。照抄 `reader_annotation_store.dart:313` 模板：加密盒 `reader_ink_annotations_v1`、key 前缀 `'i'`（`jsonEncode(['i',bookId,chapterId,...])`）、`hiveReady/_serialize/changes` 三件套、`fromMap` 容错；方法 `save/loadByChapter/delete/updateAnchor`；指纹失配返回「需人工确认」标记（枚举字段，不静默丢弃） |
| `test/ink_annotation_store_test.dart` | **新增** | 往返序列化、指纹命中/失配两路径（不依赖真机） |

### 第 4 组：PDF 接入

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| `pubspec.yaml` | **修改** | 加 pdfrx（写选型理由注释：GPL-3 兼容 + 字符坐标 + arm64） |
| `lib/services/imported_book_store.dart` | **修改** | `parseImportedBookBytes`(:446) 加 `pdf` 分支；PDF 走「存原文件」而非抽文本（`_parsePdf` 只做完整性校验 + 元信息 + 页数清点，原 PDF 存入书目录，落盘管线复用 book.json，`format:'pdf'`）；上限 `_maxBookFileBytes` 对 PDF 重估 |
| `android/app/src/main/.../LocalBookPickerPlugin.kt` | **修改** | MIME 白名单(:81–84) 加 `application/pdf`。⚠️ 在 android/ 内，属产品插件改动非「构建协议代码」，提交说明需显式声明 |
| `lib/pages/pdf_reader_page.dart` | **新增** | 路线 B1：固定版式 PDF 视图（渲染 + 翻页 + 字符位置表构建 + 进度），复用 reader 控件 |
| `lib/pages/local_book_detail_page.dart` | **修改** | `format=='pdf'` 时路由到 PdfReaderPage（subtitle 已自动显示 `本地导入 · PDF`） |
| `lib/services/library_store.dart`（或进度写入处） | **修改** | 进度记录加 `positionVersion:3`（页码型），reader_page 恢复逻辑 :2260–2267 按版本分派不受影响 |
| `docs/pdf-render-selection.md` | **新增** | 技术选型说明（任务书要求，也可并入 PR 描述） |

### 第 5 组：PDF 手写批注

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| `lib/widgets/reader/annotation/annotation_canvas.dart` | **新增** | 透明画布层：Listener 按 `event.kind == PointerDeviceKind.stylus` 过滤（手指不消费、穿透翻页）；CustomPainter 画笔迹；pressure 线性映射 + 二次贝塞尔平滑（映射参数用第 2 组实测结论） |
| `lib/widgets/reader/annotation/annotation_controller.dart` | **新增** | ViewModel 角色（仓库无 VM 层，用 ChangeNotifier/controller 类，与画布同目录）：模式开关、笔迹缓冲、撤销/重做栈、防抖保存（落盘只走 InkAnnotationStore，不落临时全局变量——护栏「Widget 不写 IO」） |
| `lib/pages/pdf_reader_page.dart` | **修改** | Stack 挂载 AnnotationCanvas（内容层之上）；批注模式锁定当前页；工具栏（笔/橡皮/撤销/重做/颜色/笔宽）样式对齐 reader_controls + ReaderMarkStyle 色板(reader_mark_style.dart:33–44) |
| `lib/services/ink_annotation_store.dart` / 模型 | **复用** | 锚点：chapterId=页 itemId，start/end 可空或=字符区间，坐标=页内归一化 |

### 第 6 组：EPUB/TXT 固定布局批注模式

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| `lib/pages/reader_page.dart` | **修改**（谨慎） | 「批注模式」入口 + 进入时以当前视口固化排版（冻结 `ReaderLayoutSpec`：字号/行距/页宽快照）+ Stack 挂 AnnotationCanvas。⚠️ 正文路径是优化期红线区，改动须最小化并全量回归 |
| `lib/services/reader_preferences.dart` | **修改** | `layoutVersion` 版本化 key（排版参数指纹），与 InkAnnotation.layoutVersion 对应 |
| AnnotationCanvas / AnnotationController / InkAnnotationStore | **复用** | 与 PDF 完全同一套（任务书要求） |
| `lib/widgets/reader/reader_chapter_layout.dart` | **复用（不改动）** | 冻结 spec 重建 layout 即「固定布局批注页」；墨迹重投影只读态可简化为区间下划线（复用 ReaderBlockMarkPainter 通道） |

### 第 7 组：锚点重投影与诊断

| 文件 | 性质 | 说明 |
| --- | --- | --- |
| `lib/services/anchor_projector.dart` | **新增** | 纯函数工具：输入锚点+当前字符位置表，输出平移+缩放矩阵；三态（精确/部分/失配），失配不自动修复 |
| `test/anchor_projector_test.dart` | **新增** | 字号/行距/页宽/横竖屏/指纹失配/区间删除/跨章边界 |
| `lib/pages/annotation_diagnostics_page.dart` | **新增** | debug 诊断页（列全部批注锚点状态） |
| `lib/pages/settings_page.dart` | **修改** | 挂诊断页入口（同第 2 组先例） |

### 跨组复用清单

`ReaderChapterLayout`（几何/分页/offset 换算，只读复用）、`ReaderAnnotationStore` 模板（Hive 存储骨架）、`ReaderHistory/LibraryStore`（进度盒）、`EncryptedHive`、`HomePalette/AppTheme`（新工具栏取色）、`reader_controls/reader_status_bar/reader_theme`（PDF 视图控件）、`reader_mark_style.dart` 色板、`Chapter`/`MediaItem` 模型（`toMediaItem()` 入书架零改动）。

---

## 6. 护栏冲突与风险清单（动工前逐条过）

1. **绝对禁改**：`rust/`、`native/`、`lib/src/rust/`（FRB 生成物，只能 codegen 更新）、`reader_theme.dart` 正文背景、正文绘制/分页/滚动/书签/进度**路径**（优化期红线，第 6 组触碰边缘须最小化 + 全量回归）。
2. **android/**：禁改的是「构建与协议代码」；LocalBookPickerPlugin.kt 加 MIME 属产品功能改动，可做，提交说明显式声明。
3. **依赖红线**：不引入新状态管理/路由/UI 框架/logger 包——pdfrx 是渲染功能依赖，不属禁止类，但「依赖调整须服务于当前任务」，pubspec 变更须写理由；不顺手升级其他依赖（版本锁：FRB 2.13.0、Flutter 3.47.7、arm64-v8a only、16KiB 对齐）。
4. **Widget 不写 IO/网络/数据库**：画布/控制器不得直写 Hive，一切落盘走 store 单例。
5. **锁竖屏（README 约定 #8）**：平板批注若要横屏，属改约定，需用户决策；未决策前一律竖屏。
6. **导入上限**：32MB 对 PDF 偏小（图文书常见 50–200MB），第 4 组须重估 `_maxBookFileBytes` 并兼顾书目录备份体积。
7. **存储分层**：PDF 原文件留明文 `imported_books/`（与 EPUB 一致）；**墨迹属用户内容，进加密 Hive**（与文本批注同规格）。
8. **验证环境**：analyze/test 只能在 ASCII 路径副本 `E:\fqapp-build2` 跑（中文路径崩溃）；基线 flutter analyze 0 问题 / flutter test 1512+10+0；真机流程见 AGENT-HANDOVER-NEXT.md §1。
9. **设备缺位**：MatePad 11 + M-Pencil 3 不在当前开发环境（只有 Redmi K20 Pro）。第 2/5/6 组验收依赖 MatePad 实测；pressure 范围/tilt 可用性/kind 区分这三个问题在 K20 Pro 上**无法最终回答**，只能等设备。
10. **进度兼容**：`positionVersion:3`（PDF 页码型）新增不动 v1/v2 读取分支；Hive key 按书 id 隔离无冲突。

---

## 7. 验收问题直答（任务书验收标准）

- **在哪里加 PDF 解析**：`lib/services/imported_book_store.dart` 的 `parseImportedBookBytes`(:446) 加 `pdf` 分支（Isolate.run :220 自动后台化）；字符位置表不落盘，在渲染层用 pdfrx `PdfTextPage` 运行时构建（`pdf_reader_page.dart`）。
- **在哪里加批注存储**：新建 `lib/services/ink_annotation_store.dart`（加密 Hive 盒 `reader_ink_annotations_v1`），模板抄 `lib/services/reader_annotation_store.dart:313`（单例 + _serialize + changes + fromMap 容错）。
- **在哪里挂手写画布层**：PDF——`pdf_reader_page.dart` 内容 Stack 的 overlay；EPUB/TXT——批注模式固化排版后，页容器外包同款 Stack；画布用 Listener 按 `PointerDeviceKind.stylus` 收笔事件，手指事件不消费留给翻页/滚动。

---

## 附：勘察覆盖面

3 个 Explore agent 实读：reader_page.dart（骨架+锚定行号）、widgets/reader/ 全目录、reader_annotation_store / reader_underline_store / reader_marker_type_store / reader_mark_preferences / note_timeline、imported_book_store.dart 全量、chapter_cache_store、library_store（进度盒）、shelf_store、api_client/backend_transport、lib/src/rust/api.dart、local_book_detail_page、library_page、settings_page、notes_page（批注链路段）、media_item.dart Chapter；人工核验：AGENTS.md、OPTIMIZATION-GUARDRAILS.md、pubspec.yaml、LICENSE、main.dart 路由、git 状态。PDF 候选包信息来自 pub.dev/GitHub（pdfrx、pdfrx_engine），第 4 组定稿时复核版本与 16KiB 对齐。
