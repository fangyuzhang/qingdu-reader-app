# Qingdu Reading - verified release APK build (Windows PowerShell).
#
# This script intentionally refuses to produce an unsigned or debug-signed APK.
# It rebuilds the Android Rust core, builds an arm64-only release package,
# checks the signer certificate, native libraries, ABI and version, and writes
# the verification report under build/apk-verification/.

param(
    [switch]$Obfuscate,
    [switch]$SkipRustBuild,
    [switch]$ValidateOnly,
    [string]$GradleUserHome = $env:GRADLE_USER_HOME,
    [string]$FlutterRoot = $env:FLUTTER_ROOT,
    [string]$AndroidSdk,
    [string]$BuildToolsVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppDir = Split-Path -Parent $PSScriptRoot
$AndroidDir = Join-Path $AppDir 'android'
$SigningProperties = Join-Path $AndroidDir 'keystore.properties'
$ExpectedPackage = 'com.fqapp.fqapp'

function Resolve-FlutterRoot {
    param([string]$Requested)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates.Add($Requested)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:FLUTTER_ROOT)) {
        $candidates.Add($env:FLUTTER_ROOT)
    }
    $flutterCommand = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($flutterCommand -and -not [string]::IsNullOrWhiteSpace($flutterCommand.Source)) {
        $flutterBin = Split-Path -Parent $flutterCommand.Source
        if ((Split-Path -Leaf $flutterBin) -eq 'bin') {
            $candidates.Add((Split-Path -Parent $flutterBin))
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        $full = [IO.Path]::GetFullPath($candidate)
        $dart = Join-Path $full 'bin\cache\dart-sdk\bin\dart.exe'
        $packageConfig = Join-Path $full 'packages\flutter_tools\.dart_tool\package_config.json'
        $snapshot = Join-Path $full 'bin\cache\flutter_tools.snapshot'
        if ((Test-Path -LiteralPath $dart -PathType Leaf) -and
            (Test-Path -LiteralPath $packageConfig -PathType Leaf) -and
            (Test-Path -LiteralPath $snapshot -PathType Leaf)) {
            return $full
        }
    }
    throw 'Flutter SDK not found. Set FLUTTER_ROOT, pass -FlutterRoot, or put flutter on PATH.'
}

$FlutterRoot = Resolve-FlutterRoot -Requested $FlutterRoot
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    $AndroidSdk = if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $env:ANDROID_HOME
    } else {
        $env:ANDROID_SDK_ROOT
    }
}
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    throw 'Android SDK not found. Set ANDROID_HOME/ANDROID_SDK_ROOT or pass -AndroidSdk.'
}
$AndroidSdk = [IO.Path]::GetFullPath($AndroidSdk)
if (-not (Test-Path -LiteralPath $AndroidSdk -PathType Container)) {
    throw "Android SDK directory not found: $AndroidSdk"
}

Set-Location -LiteralPath $AppDir
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:no_proxy = 'localhost,127.0.0.1,::1'
$env:NO_PROXY = $env:no_proxy
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'safe.directory'
$env:GIT_CONFIG_VALUE_0 = $FlutterRoot.Replace('\', '/')
$env:HOME = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($GradleUserHome)) {
    $GradleUserHome = Join-Path $env:USERPROFILE '.gradle'
}
$env:GRADLE_USER_HOME = [IO.Path]::GetFullPath($GradleUserHome)
$env:ANDROID_USER_HOME = Join-Path $env:USERPROFILE '.android'
# Sandboxed Windows shells can report user.home as C:\. Keep Gradle and AGP
# anchored to the real profile so Android metadata is not written to the drive root.
$env:GRADLE_OPTS = "-Duser.home=$env:USERPROFILE $env:GRADLE_OPTS".Trim()

$JavaCandidates = @(
    $env:JAVA_HOME,
    $(if (Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue) {
        $java = Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        Split-Path -Parent (Split-Path -Parent $java.Source)
    }),
    $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'
    }),
    $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'
    })
) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin\java.exe')) }
$JavaCandidates = @($JavaCandidates)
if ($JavaCandidates.Count -eq 0) {
    throw 'A JDK 17 installation is required. Set JAVA_HOME first.'
}
$env:JAVA_HOME = $JavaCandidates[0]
$env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
$PreviousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $JavaVersionOutput = & (Join-Path $env:JAVA_HOME 'bin\java.exe') -version 2>&1
    $JavaExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PreviousErrorAction
}
if ($JavaExitCode -ne 0) {
    throw "Could not run Java at $env:JAVA_HOME (exit code $JavaExitCode)."
}
$JavaVersionMatch = [regex]::Match(($JavaVersionOutput -join "`n"), 'version "(?<major>\d+)')
if (-not $JavaVersionMatch.Success) {
    throw "Could not determine the Java version at $env:JAVA_HOME."
}
$JavaMajorVersion = [int]$JavaVersionMatch.Groups['major'].Value
if ($JavaMajorVersion -lt 17) {
    throw "JDK 17 or newer is required; found Java $JavaMajorVersion at $env:JAVA_HOME."
}

if (-not (Test-Path -LiteralPath $SigningProperties)) {
    throw "Release signing is not configured: $SigningProperties is missing. See README.md, section 正式签名."
}
$signing = @{}
Get-Content -LiteralPath $SigningProperties | ForEach-Object {
    if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') {
        $signing[$matches[1]] = $matches[2]
    }
}
foreach ($key in @('storeFile', 'storePassword', 'keyAlias', 'keyPassword')) {
    if (-not $signing.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($signing[$key])) {
        throw "Release signing property '$key' is missing from $SigningProperties."
    }
}
$StoreFile = $signing['storeFile']
if (-not [IO.Path]::IsPathRooted($StoreFile)) {
    $StoreFile = Join-Path $AndroidDir $StoreFile
}
$StoreFile = [IO.Path]::GetFullPath($StoreFile)
if (-not (Test-Path -LiteralPath $StoreFile)) {
    throw "Release keystore not found: $StoreFile"
}

$BuildToolsRoot = Join-Path $AndroidSdk 'build-tools'
if ([string]::IsNullOrWhiteSpace($BuildToolsVersion)) {
    $latestBuildTools = Get-ChildItem -LiteralPath $BuildToolsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner.bat') } |
        Sort-Object {
            $numeric = ($_.Name -split '-')[0]
            try { [version]$numeric } catch { [version]'0.0' }
        } -Descending |
        Select-Object -First 1
    if ($latestBuildTools) {
        $BuildToolsVersion = $latestBuildTools.Name
    }
}
if ([string]::IsNullOrWhiteSpace($BuildToolsVersion)) {
    throw "No Android build-tools with apksigner.bat were found under $BuildToolsRoot."
}
$BuildTools = Join-Path $BuildToolsRoot $BuildToolsVersion
if (-not (Test-Path -LiteralPath (Join-Path $BuildTools 'apksigner.bat'))) {
    throw "Android build-tools $BuildToolsVersion was not found at $BuildTools."
}

$PythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $PythonCommand) {
    throw 'Python 3 is required for APK verification and was not found on PATH.'
}
$NodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $NodeCommand) {
    throw 'Node.js is required for native alignment verification and was not found on PATH.'
}

if ($ValidateOnly) {
    Write-Host 'Release build prerequisites are valid.'
    Write-Host "Flutter: $FlutterRoot"
    Write-Host "Android SDK: $AndroidSdk"
    Write-Host "Build tools: $BuildToolsVersion"
    Write-Host "Java: $env:JAVA_HOME"
    return
}

if (-not $SkipRustBuild) {
    Write-Host '==> rebuilding the Android Rust core...'
    & (Join-Path $AppDir 'scripts\build_rust_backend.ps1') -SkipCodegen -Profile release
    if ($LASTEXITCODE -ne 0) {
        throw 'Android Rust core build failed.'
    }
}

$Dart = Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
$FlutterToolsPackageConfig = Join-Path $FlutterRoot 'packages\flutter_tools\.dart_tool\package_config.json'
$FlutterToolsSnapshot = Join-Path $FlutterRoot 'bin\cache\flutter_tools.snapshot'
foreach ($path in @($Dart, $FlutterToolsPackageConfig, $FlutterToolsSnapshot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Flutter build prerequisite not found: $path"
    }
}

$buildArgs = @(
    "--packages=$FlutterToolsPackageConfig",
    $FlutterToolsSnapshot,
    '--suppress-analytics',
    'build', 'apk', '--release',
    '--target-platform', 'android-arm64',
    '--no-pub'
)
if ($Obfuscate) {
    $buildArgs += @('--obfuscate', '--split-debug-info=build/symbols')
}

Write-Host '==> building the signed arm64 release APK...'
& $Dart @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw 'Flutter release build failed.'
}

$Apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $Apk)) {
    throw "Flutter reported success but no APK exists at $Apk."
}

$VersionLine = Get-Content -LiteralPath (Join-Path $AppDir 'pubspec.yaml') |
    Where-Object { $_ -match '^version:\s*' } |
    Select-Object -First 1
if ($VersionLine -notmatch '^version:\s*([^+]+)\+(\d+)\s*$') {
    throw 'Could not parse versionName/versionCode from pubspec.yaml.'
}
$VersionName = $matches[1]
$VersionCode = $matches[2]

Write-Host '==> reading the release certificate fingerprint...'
$KeyTool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
$keytoolOutput = & $KeyTool -list -v -keystore $StoreFile -alias $signing['keyAlias'] -storepass $signing['storePassword'] 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not read the release certificate from $StoreFile."
}
$fingerprintMatch = [regex]::Match(($keytoolOutput -join "`n"), 'SHA256:\s*([0-9A-Fa-f:]+)')
if (-not $fingerprintMatch.Success) {
    throw 'Could not parse the release certificate SHA-256 fingerprint.'
}
$SignerSha256 = ($fingerprintMatch.Groups[1].Value -replace ':', '').ToLowerInvariant()

$ReportDir = Join-Path $AppDir "build\apk-verification\$VersionName+$VersionCode"
Write-Host '==> verifying APK signature, ABI, native libraries and version...'
& $PythonCommand.Source (Join-Path $AppDir 'scripts\verify_android_apk.py') `
    --apk $Apk `
    --build-tools $BuildTools `
    --report-dir $ReportDir `
    --expected-signer-sha256 $SignerSha256 `
    --expected-version-name $VersionName
if ($LASTEXITCODE -ne 0) {
    throw 'APK verification failed.'
}

$Core = Join-Path $AppDir 'android\app\src\main\jniLibs\arm64-v8a\libfqapi_core.so'
& $NodeCommand.Source (Join-Path $AppDir 'scripts\check_native_alignment.cjs') $Core
if ($LASTEXITCODE -ne 0) {
    throw '16 KiB native library alignment verification failed.'
}

$SizeMb = [math]::Round((Get-Item -LiteralPath $Apk).Length / 1MB, 1)
Write-Host ''
Write-Host "Release verified: $Apk"
Write-Host "Package: $ExpectedPackage  Version: $VersionName ($VersionCode)  Size: $SizeMb MB"
Write-Host "Signer SHA-256: $SignerSha256"
Write-Host "Report: $ReportDir"
