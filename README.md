# 青茄阅读

面向 12–18 岁读者的纯净小说与听书 Android 应用。项目基于开源 fqapp 做产品范围收窄和阅读体验增强，沿用 **GNU GPL-3.0**。

<p align="center">
  <strong>只读小说，只听书。</strong><br>
  没有短剧、漫剧、漫画和社交攀比。
</p>

## 产品范围

- **保留**：小说搜索与阅读、加密听书、精选书单、本机书架、阅读历史、批注/书摘、笔记、阅读统计、阅读报告、备份与离线阅读。
- **移除**：短剧、漫剧、漫画的全部用户入口、页面、下载器、播放器和相关资源。
- **内部保留**：Rust 签名/解密链路、Media3 与 `libshortplay_crypto.so` 仅用于小说正文和加密听书。名称沿用上游，可用于兼容已有数据，但不代表恢复视频功能。

产品定位和前台入口以 `lib/main.dart`、`lib/pages/home_page.dart`、`lib/pages/search_page.dart` 为准确入口。

## 主要功能

| 功能 | 说明 |
| --- | --- |
| 首页 | 本地编辑精选书单，推荐 / 7 个阅读分类 / 听书；固定分类栏与搜索入口 |
| 搜索 | 综合、小说、听书三类；支持关键词和作品 ID；列表最多只接受 `book`、`audio` |
| 阅读器 | 分页或滚动、字号/主题/亮度、按句长按选择、跨章无缝滚动、护眼提醒 |
| 批注 | 划线、书摘、行内批注块、笔记汇总，点笔记回到原文位置 |
| 书架 | 在读 / 想读 / 读完分组，浏览历史，批量整理，离线缓存 |
| 听书 | 智能朗读与真人讲书、倍速、自动下一章、定时关闭、后台播放、通知控制、边听边读 |
| 阅读统计 | 阅读时长、字数、打卡、热力图和可导出的阅读报告 |
| 数据 | 本机书架、历史、批注和偏好；支持整库备份与恢复 |
| 辅助 | 12+/15+ 分级提示、TTS、本地字体、日志导出和系统分享 |

## 技术架构

- Flutter UI；进程内 Rust 核心 `fqapi_core` 通过 `flutter_rust_bridge` 调用。
- Rust 在 `127.0.0.1:8080` 提供 loopback 阅读页和 API 适配，无需 root 或独立服务器。
- Android 原生 Media3/ExoPlayer 负责加密听书；CENC 解密库由 `native/CMakeLists.txt` 构建。
- 状态使用 Hive/Hive CE 与 SharedPreferences；敏感凭据使用 Android Keystore 支持的安全存储。
- 仅构建 `arm64-v8a`，Native 库要求 16 KiB 对齐。

## 构建

### 环境

- Flutter 3.47.7 stable / Dart SDK 满足 `pubspec.yaml` 的 `^3.12.2`
- Android SDK 36、NDK 28.2.13676358、JDK 17、Gradle 9.1.0
- Rust stable；`flutter_rust_bridge` 固定 2.13.0

### 正式签名

正式构建**必须**提供真实 keystore，缺少材料时会直接失败，不会回退 Android debug 证书。

本机将以下四项放在被 Git 忽略的 `android/keystore.properties`：

```properties
storeFile=<绝对路径或相对 android/ 的路径>
storePassword=<密码>
keyAlias=<别名>
keyPassword=<密码>
```

CI 也可通过 `RELEASE_KEYSTORE_FILE`、`RELEASE_STORE_PASSWORD`、`RELEASE_KEY_ALIAS`、`RELEASE_KEY_PASSWORD` 提供。不要把 keystore 或密码提交到仓库。

### 构建 release APK

```powershell
$env:ANDROID_HOME = '<Android SDK>'
$env:JAVA_HOME = '<JDK 17>'
# 可选；未设置时脚本会从 PATH 探测 Flutter
$env:FLUTTER_ROOT = '<Flutter SDK>'
.\tool\build_release.ps1 -ValidateOnly
.\tool\build_release.ps1
```

脚本会：

1. 检查正式签名配置；
2. 构建 `arm64-v8a` release APK；
3. 校验正式证书、包名、版本、ABI、原生库、16 KiB 对齐和 zip 对齐；
4. 将报告写入 `build/apk-verification/<version>/`。

产物：`build/app/outputs/flutter-apk/app-release.apk`。

脚本会自动选择 Android SDK 中最新的 Build-Tools；也可显式传入 `-FlutterRoot`、`-AndroidSdk`、`-BuildToolsVersion`。`-ValidateOnly` 只检查签名、SDK、Flutter、Java、Python 与 Node 前置条件，不执行构建。

## 验证

```powershell
flutter analyze --no-pub
flutter test
node --test test/web_assets_test.cjs
.\scripts\run_rust_host_tests.ps1

# Android JVM 单元测试（需要本机 Gradle/Maven 依赖）
Set-Location android
.\gradlew.bat :app:testDebugUnitTest -Ptarget-platform=android-arm64
```

当前交付的验证数字、APK 哈希和未验项记录在 `QINGQIE-CHANGES.md` 与本机 `HANDOVER.md`。测试数字会随删改而变，不能把旧版本结果当作当前结果。

## 隐私与边界

- 不提供账号写入、社交排名、付费绕过或内容分发服务。
- 只读账号导入仅在本机读取书架/历史/进度，不回写上游。
- 阅读数据、批注和备份默认保存在本机。
- 本项目仅供学习研究；使用者应遵守内容版权和所在地法律。

## 许可

GNU GPL-3.0，详见 [LICENSE](LICENSE)。保留上游版权和署名。