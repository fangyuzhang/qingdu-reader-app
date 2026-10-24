# PDF 渲染方案选型说明（第 4 组交付物）

> 结论：**pdfrx 2.2.x**（锁定 `>=2.2.0 <2.3.0`），PDFium 内核。
> 详细对比见 EXTENSION-SURVEY-REPORT.md §4.3，本文记录最终决策与理由。

## 为什么选 pdfrx

1. **字符坐标是硬前提**：手写墨迹批注（第 5–7 组）要求「某一页某个字符的坐标」
   做文本区间锚点。候选中只有 pdfrx 通过 PDFium 文本 API 暴露
   `PdfPage.loadText() → PdfPageRawText{fullText, charRects}`（逐字符矩形，
   PDF 用户坐标系）。flutter_pdfview / pdfx 都没有文本提取；MuPDF 系有但
   AGPL 许可证风险；Syncfusion 商业许可与 GPL-3.0 不兼容。
2. **许可证兼容**：pdfrx 插件 MIT；PDFium 二进制 Apache-2.0 / BSD-3-Clause
   （bblanchon/pdfium-binaries 预编译分发）。与本项目 GPL-3.0 兼容。
3. **渲染即原版式**：PDFium 渲染原页面位图，天然满足固定版式批注
   （路线 B，见勘察报告 §4.4）。

## 为什么锁 <2.3.0

pdfrx 2.3.0 起 Android/Windows 改用 **Dart native assets**：其 pdfium_dart
构建钩子会在 `flutter test`（宿主 windows_x64）上要求 MSVC 编译一个 C 门面库，
本机无 Visual Studio → 整个测试套件直接失败（已实测）。2.2.x 的 Android 端由
插件 Gradle/CMake 下载预编译 libpdfium.so，无宿主编译需求。上游 CI（非 GFW
环境）不受影响；本机锁定 2.2.x 属环境适配，升级 2.3+ 需先解决宿主编译器或等
上游提供预编译门面库。

## 构建环境适配（pub 缓存补丁，非仓库改动）

本机直连 github.com 被断 + 无符号链接权限，pdfium_flutter 0.1.9 的 CMake
configure 需要两处适配（均在 pub 缓存内，`flutter pub cache repair` 会还原）：

1. `pdfium_flutter-0.1.9/android/CMakeLists.txt` 的 `file(DOWNLOAD)` 改走
   `ghproxy.net` 镜像下载预编译 PDFium（chromium/7520）。
2. 同文件 Windows 宿主分支：`.lib/latest` 由符号链接改为**合并式拷贝**
   （原版 `file(REMOVE)` + `CREATE_LINK`：无 symlink 权限会失败，且并行
   多 ABI configure 会互删最新目录——曾导致 libpdfium.so 未打进 APK）。
3. `pdfrx_engine-0.3.9/lib/src/native/pdf_file_cache.dart` 两处闭包内
   `cache.` 空安全提升丢失的 AOT 编译错误，补 `cache!.`。

## 产物核验

- APK 含 `lib/arm64-v8a/libpdfium.so`（4,977,432 字节）。
- ELF LOAD 段 p_align=16384，满足 16KiB 对齐红线
  （核验脚本：解析 APK 内 .so 的 program headers）。
