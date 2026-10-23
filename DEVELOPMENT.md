# 青茄阅读开发说明

本文件描述当前产品形态（v35 批次，`1.0.129+134`）。旧版上游的短剧、漫剧、漫画功能不再属于前台产品范围；本地历史笔记只能作为迁移参考，不得据此恢复入口。

## 1. 产品边界

青茄阅读面向 12–18 岁，只提供小说阅读与听书。

必须保持：

- 主导航为首页 / 书架 / 笔记 / 我的。
- 首页只展示本地精选书单和听书分类，不请求上游网文推荐流。
- 搜索分类只有综合 / 小说 / 听书；综合与分页结果只能接受 `book`、`audio`。
- 书架、浏览历史和统计不为 `video`、`manju`、`manga` 提供打开入口。
- 听书关联作品优先只展示原著小说。
- 不新增短剧、漫剧、漫画、追剧、剧集下载或相关占位按钮。

内部 CENC/Media3 链路继续保留，用于加密听书和小说正文解密。`libshortplay_crypto.so` 是沿用上游的历史名称，不能只因名称含 `shortplay` 就删除。

## 2. 技术架构

```text
Flutter UI
  ├─ flutter_rust_bridge ──> Rust fqapi_core（签名、请求、解析、解密）
  ├─ MethodChannel ────────> Android 原生能力
  └─ WebView ──────────────> 127.0.0.1:8080 内置阅读页
```

- Rust 核心在应用进程内工作，不部署独立后端。
- Android 原生插件负责 Media3 播放、系统 TTS、字体选择、备份、下载、分享和墨水屏刷新。
- 仅支持 `arm64-v8a`。
- 原生 `.so` 不进入 Git，由脚本或 Gradle 构建。

### 关键目录

| 路径 | 职责 |
| --- | --- |
| `lib/pages/` | 首页、搜索、详情、阅读器、听书、书架、笔记、统计、设置 |
| `lib/widgets/` | 阅读器排版、批注、首页、书架和通用组件 |
| `lib/services/` | 本地存储、API、播放控制、备份、分享和阅读统计 |
| `lib/models/` | 上游返回与本地实体的数据模型 |
| `rust/src/` | 请求签名、上游适配、正文解密与 loopback 服务 |
| `native/` | C CENC 流式解密实现与原生测试 |
| `android/app/src/main/kotlin/` | Android 插件和 Media3 宿主 |
| `assets/config/` | 精选书单、过滤配置与运行参数 |
| `test/` | Flutter/Dart 单元与组件测试 |
| `scripts/` | 构建、APK 验证、原生对齐与主机联调脚本 |
| `tool/build_release.ps1` | 正式签名 release 构建入口 |

## 3. 客户端入口

### 首页

`lib/pages/home_page.dart` 只读取 `assets/config/curated_books.json`。分类标签由本地配置生成：推荐、7 个阅读分类、听书。书籍点击后由 `CuratedResolver` 解析成上游书籍；听书优先进入 AudioPage。

### 搜索

`lib/pages/search_page.dart` 的 `_supportedKinds` 是唯一前台白名单：

```dart
const Set<String> _supportedKinds = {'book', 'audio'};
```

首屏添加和分页添加都必须用白名单过滤，同时保留所选分类的 kind 判断。修改搜索逻辑时至少运行：

```powershell
flutter test test/search_id_page_test.dart test/search_page_test.dart
```

### 书架与历史

`lib/pages/library_page.dart` 在展示层排除 `video`、`manju`、`manga`。旧数据保留以避免破坏用户本地库，但不能重新显示或打开。

### 笔记

`NotesPage` 汇总批注与书摘，点击后通过 `ReaderPage.startTextOffset` 回到原文。批注排版必须保持分页与滚动模式共用同一高度测量。

## 4. 阅读器

`lib/pages/reader_page.dart` 和 `lib/widgets/reader/` 是核心高风险区域。

- 正文按块排版，插图与行内批注块作为整块参与测量。
- 分页和滚动必须共用测量结果，禁止出现两套高度算法。
- 长按默认按句选择；句读规则与 TTS 保持一致。
- 跨章滚动使用 append-only 段窗口和停稳后裁头补偿。
- 批注输入弹层必须由 StatefulWidget 持有 controller/focus，避免退场动画期间访问已释放对象。
- 已知限制：跨章长按选区仍未实现，因为选区几何表按块下标建键会跨章冲突。

## 5. 听书

听书由 `audio_playback_controller.dart`、`native_player.dart` 和 Android `NativePlayerPlugin` 协作。

- 加密流通过 Media3 + CENC 原生库播放。
- 后台播放需要前台服务和媒体通知。
- 完成/失败/切章事件必须按当前播放代数过滤迟到回调。
- 听书与阅读器的边听边读只同步文本位置，不应启动视频能力。
- 修改 Kotlin 代码后运行 JVM 单元测试，并在真机验证前台服务、通知和锁屏控制。

## 6. 数据与隐私

- Hive/Hive CE：书架、历史、阅读时长、批注等。
- SharedPreferences：阅读偏好、外观和轻量状态。
- `flutter_secure_storage`：加密密钥等敏感本机数据。
- 账号导入是只读的，不回写上游。
- keystore、密码、设备池真实配置、构建缓存和下载内容不得入库。

## 7. 构建与签名

本机在 `android/keystore.properties` 配置四项：`storeFile`、`storePassword`、`keyAlias`、`keyPassword`。CI 使用对应环境变量。release 构建不允许回退 debug 签名。

```powershell
$env:ANDROID_HOME = '<Android SDK>'
$env:JAVA_HOME = '<JDK 17>'
# 可选；未设置时脚本会从 PATH 探测 Flutter
$env:FLUTTER_ROOT = '<Flutter SDK>'
.\tool\build_release.ps1 -ValidateOnly
.\tool\build_release.ps1
```

脚本会从 `FLUTTER_ROOT` 或 PATH 探测 Flutter，从 `ANDROID_HOME` / `ANDROID_SDK_ROOT` 探测 Android SDK，并选择最新的可用 Build-Tools。也可显式传入 `-FlutterRoot`、`-AndroidSdk`、`-BuildToolsVersion`；`-ValidateOnly` 只检查前置条件，不执行构建。

脚本会构建并自动调用 `scripts/verify_android_apk.py`，检查证书、版本、包名、ABI、原生库、16 KiB 对齐和 zip 对齐。

## 8. 验证矩阵

| 改动面 | 最低验证 |
| --- | --- |
| Dart 逻辑 / UI | `flutter analyze --no-pub` + 定向 `flutter test` |
| 共享数据 / 搜索 / 播放 | Flutter 全量 `flutter test` |
| Rust 主机接口 | `scripts/run_rust_host_tests.ps1` 和 `cargo test` |
| Web 内置页面 | `node --test test/web_assets_test.cjs` |
| Android Kotlin | `:app:testDebugUnitTest` + release 编译 |
| APK | `tool/build_release.ps1` 的自动验证 |
| 后台/系统交互 | 真机安装、启动、页面与日志验收 |

当前测试数字由 `QINGQIE-CHANGES.md` 和本机交接文档记录。不要沿用旧版本数字。

## 9. 发布纪律

- 新 APK 只能归档到新的 `release-archives/<tag>/`，不得覆盖旧归档。
- 归档至少包含 APK、`SHA256SUMS`、`VERIFICATION.md` 和验证报告。
- 未做真机验收时，必须明确写“未做”，不能把构建成功表述为真机通过。
- 不主动推送远端或创建 Release，除非用户明确要求。

## 10. 已知限制

- FFmpeg CENC 集成测试需要本机安装 `ffmpeg`；缺失时该组测试不会执行。
- Windows 上真实 JNI 测试有 2 条按设计跳过。
- 跨章长按选区尚未实现。
- 沙箱环境可能限制 `Path.toRealPath`、ADB 或 Gradle 目录 classpath；常规开发机不应把这些环境限制带入业务代码。
