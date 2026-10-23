# 青茄阅读 · qingqie-reader-app

面向 12–18 岁读者的**纯净小说与听书** Android 阅读器。
Flutter 负责 UI 与阅读体验，Rust 以进程内库的形式承担上游接口签名与正文解密，Android 原生层负责加密听书播放。

<p align="center">
  <strong>只读小说，只听书。</strong><br>
  没有短剧、漫剧、漫画，也没有社交攀比。
</p>

| 项目 | 值 |
| --- | --- |
| 仓库 | 私有仓库 `fangyuzhang/qingqie-reader-app` |
| 当前版本 | `1.0.129+134` |
| 包名 | `com.fqapp.fqapp` |
| 系统要求 | Android 7.0+（`minSdk 24`），`targetSdk 36` |
| ABI | 仅 `arm64-v8a`，Native 库 16 KiB 对齐 |
| 许可证 | GNU GPL-3.0 |
| 最近更新 | 2026-10-23（UI 可访问性与首页 / 我的 交互收口） |

## 文档索引

| 文档 | 用途 |
| --- | --- |
| `README.md` | 产品范围、功能、架构、构建与验证（本文） |
| `QINGQIE-CHANGES.md` | 逐批改造记录：改了什么、为什么、如何验证 |
| `AGENT-HANDOVER-NEXT.md` | **接手先看**：当前代码状态、命令、已知问题 |
| `AGENT-HANDOVER.md` | 早期总交接归档（历史背景，状态已过期） |
| `AGENTS.md` / `DEVELOPMENT.md` | 协作规则与开发约定 |

## 产品范围

- **保留**：小说搜索与阅读、加密听书、精选书单、本机书架、阅读历史、批注 / 书摘、笔记、阅读统计、阅读报告、备份与离线阅读。
- **移除**：短剧、漫剧、漫画的全部用户入口、页面、下载器、播放器和相关资源。
- **内部保留**：Rust 签名 / 解密链路、Media3 与 `libshortplay_crypto.so` 仅服务于小说正文和加密听书；名称沿用上游以兼容既有数据，不代表恢复视频功能。

前台入口以 `lib/main.dart`、`lib/pages/home_page.dart`、`lib/pages/search_page.dart` 为准。

## 功能一览

| 模块 | 说明 |
| --- | --- |
| 首页 | 本地精选书单，每日轮换；推荐 / 7 个阅读分类 / 听书；固定分类栏与搜索入口 |
| 首页分类书架 | 横向书卡滑到末端后**继续右滑**直接进入该分类「全部」页；卡片文案为「精选书单 · 查看全部」 |
| 搜索 | 综合 / 小说 / 听书三类；支持关键词与作品 ID；列表只接受 `book`、`audio` |
| 阅读器 | 分页或上下滚动、5 套背景、字体字号行距、亮度、跨章无缝滚动、护眼提醒 |
| 选择与批注 | 长按按句选择、划线 / 虚线 / 波浪线 / 荧光笔、行内批注块、自定义批注类型 |
| 笔记 | 时间线 / 按书查看（与首页同款封面网格，选书后留在本视图）/ 划线视图；一条笔记可挂多个类型角标；书名固定在标题行、标签独占一行；类型与标签都可多选筛选；「全部类型」一行支持长按拖拽打标、跨笔记移动、拖到空白处取消，以及手机式「挤进去」排序（拖回自己卡片时有半透明角标 + 吸附环提示） |
| 书架 | 在读 / 想读 / 读完分组，封面立体与列表双模式，批量整理，离线缓存 |
| 听书 | 智能朗读与真人讲书、倍速、自动下一章、定时关闭、后台播放、通知控制、边听边读 |
| 听书详情 | 小封面 + 当前章节、整章逐句可滚正文、当前句高亮、长按「从本句听」、页码与全书进度 |
| 阅读统计 | 阅读时长、估算字数、打卡热力图、每日阅读、可导出的阅读报告、日期切换入口 |
| 数据 | 本机书架 / 历史 / 批注 / 偏好；整库备份与恢复 |
| 辅助 | 12+ / 15+ 分级提示、TTS、本地字体、日志导出、系统分享 |

## 界面与交互约定（改动前务必确认）

这些是踩过坑之后定下的规则，改 UI 时不要无意中推翻：

1. **首页不设滚动悬浮搜索按钮。** 下滑后浮出的搜索按钮已移除，搜索只保留固定顶栏入口。
2. **分类卡不写「精选 N 本」。** 「全部」页会继续从书城追加书目，写死数量必然对不上，统一用「精选书单 · 查看全部」。
3. **横向书架「滑到底再滑」= 查看全部。** 到末端后累计过冲约 `72dp` 触发一次，并给一次轻震动；阈值过小会被正常甩动误触。
4. **可点区域 ≥ 48dp。** 视觉尺寸可以小（27dp 胶囊、17dp 图标），命中区必须补到 48dp：分类 chip、tab、版式分段、笔记类型筛选均按此处理。
5. **小字号文字对比度 ≥ 4.5:1。** 次要文字浅色统一 `#5E6B64`（5.37:1），强调小字 `#176B58`（6.16:1），阅读器辅助文字用正文色 80% 透明度。
6. **工具栏覆盖正文，不挤压正文。** 显隐工具栏与系统状态栏时正文位置不变；仅第一页允许留出顶部安全区。
7. **正文沉浸态与系统栏联动。** 工具栏收起 → 状态栏与手势条隐藏；展开 → 一并恢复；退出阅读页恢复系统栏。
8. **全应用锁竖屏。** `main.dart` 设定竖屏，`MainActivity` 另有 `screenOrientation="portrait"` 兜底。
9. **全局日夜与阅读器背景同源。** 工具栏切换日夜会同步整机主题，反之亦然。

## 目录结构

```
lib/
  main.dart              应用入口、底部导航、竖屏锁定、全局主题
  pages/                 首页、搜索、详情、阅读器、书架、笔记、统计、设置……
  widgets/               首页卡片、书架卡片、阅读器（正文 / 工具栏 / 批注 / 状态行）
  services/              主题、统计、听书、缓存、备份、网络与本地存储
  models/                数据模型
rust/                    进程内核心 fqapi_core（签名、解密、loopback 适配）
native/                  CENC 解密库（CMake）
android/                 Media3 播放、签名配置、清单
test/                    Widget / 单元 / 集成测试
```

## 技术架构

- Flutter UI；Rust 核心 `fqapi_core` 通过 `flutter_rust_bridge`（固定 2.13.0）调用。
- Rust 在 `127.0.0.1:8080` 提供 loopback 阅读页与 API 适配，无需 root 或独立服务器。
- Android 原生 Media3 / ExoPlayer 负责加密听书；CENC 解密库由 `native/CMakeLists.txt` 构建。
- 状态使用 Hive / Hive CE 与 `SharedPreferences`；敏感凭据走 Android Keystore 支持的安全存储。
- 仅构建 `arm64-v8a`；Native 库与 zip 条目均要求 16 KiB 对齐。

## 开发环境

| 依赖 | 版本 / 路径 |
| --- | --- |
| Flutter | 3.47.7 stable（Dart `^3.12.2`） |
| Android SDK | 36，Build-Tools 36.0.0 |
| NDK | 28.2.13676358 |
| JDK | 17 |
| Gradle | 9.1.0 |
| Rust | stable |

> 仓库与工具链都在 WSL 原生路径（`/home/fy/...`）。`/mnt/*` 走 9p，编译会明显变慢。
> 若 shell 命中 `/mnt/d/.../flutter` 的包装脚本并报 `$'\r'`，把 `$HOME/flutter/bin` 前置到 `PATH`。

```bash
export PATH=$HOME/flutter/bin:$HOME/jdk17/bin:$PATH
export JAVA_HOME=$HOME/jdk17
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$HOME/Android/Sdk
```

## 构建

### 正式签名

正式构建**必须**提供真实 keystore，缺少材料会直接失败，不会回退 debug 证书。
把四项写进被 Git 忽略的 `android/keystore.properties`：

```properties
storeFile=<绝对路径或相对 android/ 的路径>
storePassword=<密码>
keyAlias=<别名>
keyPassword=<密码>
```

CI 可用 `RELEASE_KEYSTORE_FILE`、`RELEASE_STORE_PASSWORD`、`RELEASE_KEY_ALIAS`、`RELEASE_KEY_PASSWORD` 提供同样的值。不要把 keystore 或密码提交进仓库。

### 构建 release APK

```bash
cd rust && cargo build --release --target aarch64-linux-android   # 需要时重建 Rust
cd .. && flutter pub get
flutter build apk --release --target-platform android-arm64
```

产物：`build/app/outputs/flutter-apk/app-release.apk`。

Windows 上也可用 `tool/build_release.ps1`，它会检查签名、构建、并校验证书 / 包名 / 版本 / ABI / 16 KiB 对齐 / zip 对齐，报告写入 `build/apk-verification/<version>/`；`-ValidateOnly` 只做前置检查。

## 验证

```bash
flutter analyze                 # 期望 0 问题
flutter test                    # 全量测试

node --test test/web_assets_test.cjs
./scripts/run_rust_host_tests.sh

# APK 静态校验（签名 / ABI / 对齐 / 清单元数据）
python3 scripts/verify_android_apk.py \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --build-tools $HOME/Android/Sdk/build-tools/36.0.0 \
  --report-dir build/apk-verification/wsl-native
```

当前基线：`flutter analyze` 0 问题；`flutter test` 通过 1488、跳过 10、失败 0。
测试数字会随增删变化，以最近一次真实运行为准，不要引用旧结果。

## 版本与发布

- 版本号在 `pubspec.yaml` 的 `version:` 一处维护（当前 `1.0.129+134`）。
- `master` 是唯一开发分支；每个批次一条独立提交，记录同步写进 `QINGQIE-CHANGES.md`。
- 基准：tag `baseline-1.0.129-20261023`（提交 `0bea552`），附 38,524,657 字节基准 APK。
- 当前 `master`：tag `v35-20261023`（提交 `e78f93a`），APK 38,524,655 字节，SHA-256 `130b302f6aa8310974c19b090053383189d9d273692bb75182b013b70dd31041`。

## 已知限制

- 日期选择弹层文案仍是英文（`Select date / Cancel / OK`），项目尚未接入 `flutter_localizations`。
- 墨水屏背景下仍有若干处直接引用 `HomePalette.accent`，未全量替换为语义色。
- 阅读器批注块内 3 个 16dp 图标按钮热区不足 48dp，但宽度参与分页折算，暂未改动。
- 仅支持 `arm64-v8a` 与 Android 7.0+，不提供 iOS / 桌面端。
- 依赖上游接口可用性，上游策略变化可能影响搜索与正文加载。

## 隐私与边界

- 不提供账号写入、社交排名、付费绕过或内容分发服务。
- 只读账号导入仅在本机读取书架 / 历史 / 进度，不回写上游。
- 阅读数据、批注与备份默认保存在本机。
- 本项目仅供学习研究；使用者应遵守内容版权与所在地法律。

## 许可

GNU GPL-3.0，详见 [LICENSE](LICENSE)。保留上游版权与署名。
