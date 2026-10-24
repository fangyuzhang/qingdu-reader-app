# 青茄阅读 · 当前状态交接（AGENT-HANDOVER-NEXT）

> 更新时间：2026-10-24
> 仓库：`/home/fy/projects/fqapp-src`（WSL2 **原生路径**，不是 `/mnt/c` 上的副本）
> 远端：`https://github.com/fangyuzhang/qingqie-reader-app`（**私有**）
> 分支：`master`　功能基线：`236ca3b`（UI 交互动画）　HEAD：以 `git log --oneline -1` 为准（其后的文档同步提交）
> 版本：`1.0.131+136`　包名：`com.fqapp.fqapp`

本文是**唯一有效的当前状态说明**。`AGENT-HANDOVER.md` 是早期总交接归档，里面的 HEAD、测试数字、工作树描述都已过期，只能当历史背景读。

---

## 0. 30 秒速览

| 项 | 值 |
| --- | --- |
| 代码状态 | `master` 已提交；功能提交 `236ca3b`，本交接文档随后单独提交，工作区保持干净 |
| 测试基线 | `flutter analyze` 0 问题；`flutter test` 通过 **1510**、跳过 **10**、失败 **0** |
| 真机 | Redmi K20 Pro，serial `b2f8e975`（adb 走 Windows 侧 exe） |
| 当前 APK | 38,459,043 字节，SHA-256 `57972b2305c91d2222a2b2d3ed7363af5586a26837cf70a7f25a8e84d5ec1680`（`/mnt/d/APP/agent/apk/fqapp-ui-animation.apk`，版本 1.0.131+136） |
| APK 校验 | 本批只做了安装与真机截图复核；v35 的静态校验报告仍在 `build/apk-verification/wsl-native-v35/report.json` |
| 当前批次 | UI 动画：书架选中态 / 封面 Hero / 统一弹窗与主题渐变 / 翻页 280ms / 首屏错峰入场 |

接手第一件事：跑第 5 节的 `flutter analyze && flutter test`，确认基线仍是 1510/10/0，再动手。

---

## 1. 环境与固定命令

### 1.1 路径

| 项目 | 值 |
| --- | --- |
| 仓库 | `/home/fy/projects/fqapp-src` |
| Flutter | `$HOME/flutter/bin/flutter` |
| JDK | `$HOME/jdk17`（17） |
| Android SDK | `$HOME/Android/Sdk`（build-tools `36.0.0`） |
| NDK | `28.2.13676358` |
| adb（Windows 侧） | `/mnt/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe` |
| 真机 serial | `b2f8e975` |
| APK 中转 | `/mnt/d/APP/agent/apk/` |

### 1.2 每次开新 shell 先导出

```bash
export PATH=$HOME/flutter/bin:$HOME/jdk17/bin:$PATH
export JAVA_HOME=$HOME/jdk17
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$HOME/Android/Sdk
cd /home/fy/projects/fqapp-src
```

> 坑：默认 `PATH` 可能先命中 `/mnt/d/.../flutter` 的包装脚本，报 `$'\r': command not found`。
> 把 `$HOME/flutter/bin` 放在最前面即可。所有构建都应在 WSL 原生路径执行，`/mnt/*` 走 9p，编译会慢一大截。

---

## 2. 仓库与 Git 规则

- 远端只有一个：`origin` → `https://github.com/fangyuzhang/qingqie-reader-app.git`，**私有仓库**。
- 历史仓库 `fangyuzhang/fqapp-qingqie`、`fangyuzhang/qingqie-reader` 已停用，不要往那边推。
- 本机直连 `github.com:443` 会超时（TLS 被中断），推送走镜像：全局 `gitconfig` 已配 `url."https://ghproxy.net/https://github.com/".insteadOf`，仓库内另配了 `credential."https://ghproxy.net".helper`（运行时用 `gh auth token` 取令牌）。`remote.origin.url` 保持标准写法即可，`git remote -v` 显示展开后的 ghproxy 地址属正常。
- 推送后务必用 `git ls-remote --heads origin master` 核对远端 SHA 等于本地 `git rev-parse HEAD`。
- 提交粒度：一个批次一条提交，标题用 `area: 结果`，正文写「为什么 / 怎么验 / 影响面」。
- 文档与代码同批提交：改了行为就同步 `QINGQIE-CHANGES.md`；改了状态就同步本文。
- 不要执行 `git reset --hard`、`git checkout .`、`git clean -fdx`：`build/`、`release-archives/`、`rust/target/` 虽被忽略，但删掉要重建很久。

---

## 3. 当前功能状态

### 3.1 首页

- 本地精选书单，按天轮换；推荐 / 7 个阅读分类 / 听书三个区。
- 固定顶栏含搜索入口。**下滑不再浮出搜索按钮**（已移除，含滚动监听）。
- 分类卡文案统一「精选书单 · 查看全部」，不再写「精选 N 本」（「全部」页会追加书城结果，数量对不上）。
- 横向书架 `_CategoryRail`：滑到末端后继续右滑累计约 `72dp` → 轻震动 + 进入该分类「全部」。

### 3.2 搜索 / 详情

- 综合 / 小说 / 听书三类；支持关键词与作品 ID；结果只保留 `book`、`audio`。
- 详情页首屏拆成「detail 先到先上屏 + 快照同帧渲染」，并预热续读章节正文与插图。
- 按钮位置：左下「加入书架」（略放大），右上「下载」；正文工具栏右上角同样是「加入书架」。

### 3.3 阅读器

- 分页 / 上下滚动两种模式；5 套背景（米白、青绿、纸张、夜间、墨水屏）；字号、行距、亮度可调。
- 上下滚动跨章无缝：章首继续下拖接上一章末尾，窗口只增不减。
- 工具栏与系统状态栏**覆盖**正文，不挤压正文；仅第一页留顶部安全区。
- 沉浸态联动：工具栏收起 → `immersiveSticky`（状态栏 + 手势条隐藏）；展开 → `edgeToEdge`；退出恢复。
- 全应用锁竖屏（`main.dart` + `MainActivity` 双保险）。
- 长按按句选择，弹出「从本段开始听书 + 4 个操作」；预选项未点击就点别处时，按当前线型直接落笔。
- 批注插入在**批注行的下一行**；行内批注块支持疑问 / 反驳 / 感悟 / 待查证 + 自定义类型。
- 状态行：左下 `当前页/总页数` + 百分比，右下电量；两者间留约两个数字宽的空档。

### 3.4 笔记

- 三个视图：时间线 / 按书查看（与首页同款封面网格）/ 划线。
- 按书、时间、类型、标签可单独或组合筛选；类型筛选行命中区 48dp。
- 时间轴日期强制单行，不再折行把条目顶歪。

### 3.5 书架

- 在读 / 想读 / 读完分组 + 浏览历史；封面立体与列表双模式；批量整理；离线缓存。
- 分组 chip、tab、版式分段命中区均 48dp，视觉尺寸刻意不变。
- 进度角标 11sp，深珊瑚渐变；列表模式用字重与颜色拉开书名 / 作者 / 进度层次。

### 3.6 听书

- 真人讲书与系统朗读共用同一套听书详情页：小封面 + 当前章节、整章逐句可滚正文、当前句高亮、「从本句听」、页码与全书进度。
- 系统朗读逐句送引擎，正文只亮当前句，不再整段一起亮。
- 悬浮胶囊：工具栏展开时是 232×48 可拖动胶囊（暂停 / 关闭 / 听书设置），收起时收为底部 128×38 小按钮（继续听书 / 停止听书）。
- 定时关闭、语速、音色在胶囊的「听书设置」里。
- 护眼提醒（连续 45 分钟）层级最高，弹窗期间胶囊不渲染。
- 切章无音源时自动转系统朗读；退出听书不再出现黑屏「已关闭」页，直接回详情。

### 3.7 我的 / 统计

- 入口只剩：AppBar 右上角「日夜切换 + 设置」；body 是 `StatsPage(header: ...)`。
- 「阅读热力图」与「每日记录」已合并为一套：点击热力图进详情，详情内含每日阅读时长，不再两套并行实现。
- 日期旁有「📅 选择日期 ⌄」胶囊，整块可点，大字号下 `Wrap` 换行不挤压。
- 设置页：主题当前值用 `muted` token，服务状态用 `ColorScheme` 语义色。

---

## 4. 代码地图

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 入口、底部导航、竖屏锁定、全局主题注入 |
| `lib/services/app_theme.dart` | `ThemeData` / `ColorScheme` / 文本色 token（浅色 muted `#5E6B64`） |
| `lib/widgets/app_dialog.dart` | 全应用统一弹窗：180ms 淡入 + 轻微上滑；墨水屏/减少动画瞬时 |
| `lib/widgets/home/home_design.dart` | 首页配色 `HomePalette`（muted、accentText、soft） |
| `lib/pages/home_page.dart` | 首页、分类区、`_CategoryRail`（滑到底进全部） |
| `lib/pages/library_page.dart` | 书架、分组 chip / tab / 版式分段 |
| `lib/pages/reader_page.dart` | 阅读器主体、分页与滚动、结算阅读时长与字数 |
| `lib/widgets/reader/reader_theme.dart` | 5 套阅读背景与正文 / 辅助文字 / 强调色 |
| `lib/widgets/reader/reader_status_bar.dart` | 阅读器状态行（页码、百分比、电量） |
| `lib/widgets/reader/reader_note_block.dart` | 行内批注块 |
| `lib/pages/notes_page.dart` | 笔记三视图与筛选 |
| `lib/pages/stats_page.dart` | 热力图、每日阅读、日期入口 |
| `lib/pages/mine_page.dart` | 我的页骨架（AppBar + StatsPage header） |
| `lib/services/reading_stats_store.dart` | 字数与时长口径、旧数据迁移 |
| `lib/widgets/book_thumb.dart` | 统一小封面 |
| `rust/` | `fqapi_core`：签名、解密、loopback 适配 |
| `native/` | CENC 解密库（CMake） |

---

## 5. 构建与验证

### 5.1 校验

```bash
flutter analyze
flutter test
```

当前期望：`analyze` 0 问题；`test` 1510 通过 / 10 跳过 / 0 失败。

### 5.2 构建 release

```bash
flutter build apk --release --target-platform android-arm64
```

产物 `build/app/outputs/flutter-apk/app-release.apk`。签名读 `android/keystore.properties`（已被 Git 忽略），缺失会直接失败，不会退回 debug 证书。

### 5.3 APK 静态校验

```bash
python3 scripts/verify_android_apk.py \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --build-tools $HOME/Android/Sdk/build-tools/36.0.0 \
  --report-dir build/apk-verification/wsl-native
```

覆盖：zip 条目数、Native 库清单、ELF 16 KiB 对齐、zip 16 KiB 对齐、签名、清单元数据、APK 未被改动。

### 5.4 装机与取证

```bash
ADB=/mnt/d/APP/DevTools/Android/Sdk/platform-tools/adb.exe
cp build/app/outputs/flutter-apk/app-release.apk /mnt/d/APP/agent/apk/fqapp-v37.apk
$ADB -s b2f8e975 install -r /mnt/d/APP/agent/apk/fqapp-v37.apk
$ADB -s b2f8e975 shell am start -n com.fqapp.fqapp/.MainActivity
$ADB -s b2f8e975 exec-out screencap -p > /tmp/shot.png
```

---

## 6. 真机复核清单

每批 UI 改动至少覆盖这些点（本轮已全部通过，回归时照单重跑）：

- [ ] 首页下滑不出现浮动搜索按钮；顶栏搜索仍可进搜索页。
- [ ] 首页横向书架滑到末端继续右滑 → 进入对应分类「全部」，且有轻震动。
- [ ] 「全部」页显示真实数量（如「古典名著」已载入 40 本），文案不再是固定 6 本。
- [ ] 我的页日期胶囊可点，选择日期后统计范围刷新。
- [ ] 笔记时间轴日期单行，条目不错位。
- [ ] 笔记「全部类型」行同时列出批注类型与自由标签；点类型/标签只做切换，再点取消，没有「类型 X / 清除」二级按钮。
- [ ] 长按类型或标签拖到笔记上可打标；把笔记上的角标拖到空白处即取消；拖到另一条笔记即移动。
- [ ] 长按标签拖到另一个标签后面可换序，重启应用后顺序保留。
- [ ] 「按书查看」选中一本书后停留在本视图，顶部有返回条，不自动跳回时间线。
- [ ] 5 套阅读背景下正文与辅助文字都清晰（尤其夜间、墨水屏）。
- [ ] 系统字号放大后，书架 chip、笔记筛选、我的页日期不溢出。
- [ ] 正文工具栏显隐时正文不上下移动。
- [ ] 沉浸态状态栏与手势条隐藏，展开后恢复，退出阅读页恢复。
- [ ] 听书胶囊双形态、护眼弹窗置顶、切章可继续播放。

---

## 7. 已知问题与下一步

| 优先级 | 问题 | 说明 |
| --- | --- | --- |
| 中 | 日期选择器文案是英文 | 需引入 `flutter_localizations` 并在 `MaterialApp` 配 `zh_CN`，属新增依赖 |
| 中 | 墨水屏仍有 93 处直接引用 `HomePalette.accent / highlight` | 逐处替换为语义色，涉及分页折算时需回归阅读器 |
| 低 | 批注块内 3 个 16dp 图标热区不足 48dp | 宽度参与分页折算，改动会移动分页点 |
| 低 | 听书详情页长文本滚动性能 | 超大章节建议做窗口化，目前整章渲染 |

---

## 8. 禁忌清单

1. 不要恢复短剧 / 漫剧 / 漫画的任何入口；`shortplay` 命名只用于兼容既有数据与解密库。
2. 不要把工具栏改成挤压正文的布局。
3. 不要给分类卡写回「精选 N 本」这类固定数量。
4. 不要重新加回首页滚动悬浮搜索按钮。
5. 不要用 `git reset` / `checkout .` 清理工作区。
6. 不要在 `/mnt/*` 上跑构建。
7. 不要提交 keystore、密码、真实用户数据或抓包内容。
8. 不要把「全部」页的追加逻辑改成一次性替换，否则首屏会闪空。

---

## 9. 文档索引

| 文档 | 内容 |
| --- | --- |
| `README.md` | 产品范围、功能、交互约定、构建与验证 |
| `QINGQIE-CHANGES.md` | 从 v1 到 v35 的逐批改造记录（含对比度数值与验证证据） |
| `AGENT-HANDOVER-NEXT.md` | 本文，当前状态 |
| `AGENT-HANDOVER.md` | 早期总交接归档，仅作历史背景 |
| `DEVELOPMENT.md` | 开发约定 |
