# 青茄阅读 · 正式包一键构建（Windows PowerShell）
#
# 为什么需要这个脚本：
#   `flutter run` / `flutter build apk --debug` 装出来的 debug 包自带 JIT 内核
#   （kernel_blob.bin ≈ 128MB）、Vulkan 校验层（≈ 15MB）和未压缩的 dex，
#   手机上显示的「应用大小」会到 400MB+。这不是重构把 App 弄胖了，
#   是 debug 构建本来就这么大。日常使用请装 release 包（本脚本产物）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool\build_release.ps1
#   可选参数：
#     -Obfuscate   开启 Dart 混淆（体积再小一点，崩溃栈需要配合
#                  build/symbols 里的符号文件才能还原，日常自用可以不开）
#
# 产物：build\app\outputs\flutter-apk\app-release.apk（仅 arm64-v8a）

param(
    [switch]$Obfuscate
)

$ErrorActionPreference = 'Stop'

# 与本机环境保持一致（Flutter SDK / Android SDK 路径）。
$env:ANDROID_HOME = 'D:\APP\DevTools\Android\Sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
# 本机代理端口变化时，Gradle 走默认源会卡住；本地构建不需要代理。
$env:no_proxy = 'localhost,127.0.0.1,::1'
$env:NO_PROXY = $env:no_proxy

Set-Location (Join-Path $PSScriptRoot '..')

if ($Obfuscate) {
    flutter build apk --release --obfuscate --split-debug-info=build/symbols
} else {
    flutter build apk --release
}

$apk = 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
    $size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
    Write-Host ""
    Write-Host "构建完成：$apk（$size MB）"
    Write-Host "安装：adb install -r $apk"
}
