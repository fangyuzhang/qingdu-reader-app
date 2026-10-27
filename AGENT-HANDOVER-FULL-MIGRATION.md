# 轻读 · 完整迁移交接文档

> 更新时间：2026-10-24 08:10 (UTC+8)
> 本文档对应仓库 HEAD：`0b76acbf397ff6cbc576603c5f53565d177a2d3e`
> 版本：`1.0.131+136`　包名：`com.fqapp.fqapp`
> 本文件夹是完整迁移备份包，可在另一台电脑上继续开发，无需依赖原机任何文件。

---

## 一、文件夹结构说明

```
轻读/
├── 交接文档-完整版.md          ← 本文档（先读这个）
├── repo/
│   └── fqapp-src/              ← 完整 Git 仓库（干净 clone，含全部历史）
│       ├── pubspec.yaml        ← Flutter 项目定义（版本号在此维护）
│       ├── pubspec.lock        ← 依赖锁定文件
│       ├── lib/                ← Dart/Flutter 源码（UI + 逻辑）
│       ├── rust/               ← Rust 原生核心源码
│       ├── android/            ← Android 构建配置
│       ├── android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so  ← 预编译 Rust 库（git 忽略，已手动复制）
│       ├── android/keystore.properties ← 签名配置（git 忽略，已手动复制）
│       └── scripts/            ← 构建与验证脚本
├── signing/
│   ├── qingqie-release.jks     ← 正式签名 keystore（绝不入库）
│   └── SIGNING-SECRETS.txt     ← keystore 密码与别名（绝不入库）
├── releases/
│   └── fqapp-1.0.131+136.apk   ← 当前最新已验证 APK
└── env/
    ├── flutter-version.txt     ← Flutter SDK 版本快照
    ├── rust-version.txt        ← Rust 工具链版本
    ├── node-version.txt        ← Node.js 版本
    └── java-version.txt        ← JDK 版本
```

---

## 二、Git 仓库状态

| 项 | 值 |
| --- | --- |
| 远端 | `https://github.com/fangyuzhang/qingqie-reader-app`（私有） |
| 分支 | `master`（唯一开发分支） |
| HEAD | `0b76acbf397ff6cbc576603c5f53565d177a2d3e` |
| 追踪文件 | 543 个 |
| .git 大小 | 8.3 MiB |
| 工作区 | 干净（无未提交改动） |
| Git fsck | 无损坏对象 |

### 最近 5 条提交

| SHA | 说明 |
| --- | --- |
| `0b76acb` | docs: 记录 GitHub 推送镜像与校验方式 |
| `4f6186b` | docs: 同步 UI 动画批次交接状态 |
| `236ca3b` | feat(ui): 书架选中态与封面 Hero，统一弹窗和主题过渡 |
| `d3dbdb5` | fix(notes): 标签独占一行、书名固定、类型/标签多选与手机式挤位排序 |
| `c3d0c65` | feat(notes): 笔记类型/标签统一拖拽与多角标 |

### GitHub 推送注意事项（重要）

本机直连 `github.com:443` 会超时（GnuTLS -110）。**推送走镜像**：

全局 `~/.gitconfig` 已配置：
```
[url "https://ghproxy.net/https://github.com/"]
    insteadOf = https://github.com/
```

仓库内 `credential."https://ghproxy.net".helper` 已配置（运行时用 `gh auth token` 取令牌）。

在新电脑上需要做：
1. `gh auth login`（登录 GitHub）
2. 在 `~/.gitconfig` 加上面的 `insteadOf` 规则
3. 在仓库内运行：
   ```bash
   git config --local credential."https://ghproxy.net".username oauth2
   git config --local credential."https://ghproxy.net".helper '!f() { echo "password=$(gh auth token)"; }; f'
   ```

推送后校验：
```bash
git ls-remote --heads origin master | cut -f1
git rev-parse HEAD
# 两者应一致
```

---

## 三、签名材料（必须保留）

**位置**：`signing/` 文件夹

| 文件 | 说明 |
| --- | --- |
| `qingqie-release.jks` | 正式签名 keystore（4.5 KB） |
| `SIGNING-SECRETS.txt` | 密码文件（含 store password、key password、alias） |

**新电脑上把 keystore 配置到仓库**：

创建 `android/keystore.properties`（此文件被 .gitignore 忽略，不入库）：
```properties
storeFile=<绝对路径>/signing/qingqie-release.jks
storePassword=<见 SIGNING-SECRETS.txt>
keyAlias=qingqie-release
keyPassword=<见 SIGNING-SECRETS.txt>
```

**重要**：这两个文件是唯一签名材料。丢失后无法用同一签名身份发布更新（用户需卸载重装）。请至少保留一份云备份（加密后上传）。

---

## 四、当前 APK

| 项 | 值 |
| --- | --- |
| 文件 | `releases/fqapp-1.0.131+136.apk` |
| 大小 | 38,459,043 字节 (37 MiB) |
| SHA-256 | `57972b2305c91d2222a2b2d3ed7363af5586a26837cf70a7f25a8e84d5ec1680` |
| 版本 | 1.0.131 + 136 |
| 已验证 | 是（analyze 0 问题；test 1507 通过 / 10 跳过 / 0 失败） |
| 真机 | Redmi K20 Pro，serial `b2f8e975` |

---

## 五、开发环境依赖（新电脑上需要安装）

| 工具 | 版本 | 安装方式 |
| --- | --- | --- |
| Flutter | 3.47.7 stable | [flutter.dev](https://docs.flutter.dev/get-started/install) |
| Dart | 3.13.5 | 随 Flutter 自带 |
| Android SDK | 36 | Android Studio 或命令行 tools |
| Build-Tools | 36.0.0 | sdkmanager "build-tools;36.0.0" |
| NDK | 28.2.13676358 | sdkmanager "ndk;28.2.13676358" |
| JDK | 17 | Adoptium/OpenJDK 17 |
| Gradle | 9.1.0 | 项目自带 gradlew，首次构建自动下载 |
| Rust | stable | [rustup.rs](https://rustup.rs) |
| Node.js | 18+ | [nodejs.org](https://nodejs.org) |
| Python 3 | 3.10+ | 系统自带或 python.org |

### 环境变量设置（WSL 原生路径示例）

```bash
export PATH=$HOME/flutter/bin:$HOME/jdk17/bin:$PATH
export JAVA_HOME=$HOME/jdk17
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$HOME/Android/Sdk
```

### Flutter 精确版本

如果需要精确匹配 Flutter 版本：
```bash
cd ~/flutter
git checkout abaf9c5237
```

（Framework revision `abaf9c5237`，Engine `d8a2d6c768c334d53e16277f837970ffa1e2de81`）

---

## 六、新电脑上恢复开发（完整步骤）

### 步骤 1：把本文件夹复制到 WSL 原生路径

```bash
# 从 Windows E 盘复制到 WSL 内部（性能更好）
cp -r /mnt/e/项目/青茄阅读/repo/fqapp-src ~/projects/fqapp-src
cd ~/projects/fqapp-src
```

### 步骤 2：安装 Flutter 依赖

```bash
flutter pub get --enforce-lockfile
```

### 步骤 3：重建 Rust 原生库（可选，已带预编译 .so）

项目已附带 `libfqapi_core.so`（6.2 MB），位于：
```
android/app/src/main/jniLibs/arm64-v8a/libfqapi_core.so
```

**可以直接跑 `flutter analyze` 和 `flutter test`，不需要先重建 Rust。**

如果 Rust 源码有改动，需要重编：
```bash
bash scripts/build_rust_backend.sh
```

### 步骤 4：配置签名（如需构建 release）

按上文「三、签名材料」中的说明创建 `android/keystore.properties`。

### 步骤 5：验证

```bash
flutter analyze          # 期望 0 问题
flutter test             # 期望全部通过
```

### 步骤 6：构建 APK

```bash
flutter build apk --release --target-platform android-arm64
```

产物在 `build/app/outputs/flutter-apk/app-release.apk`。

### 步骤 7：连接 GitHub（如需推送）

```bash
gh auth login
# 然后按上文「二、Git 仓库状态」中的推送配置操作
```

---

## 七、已知注意事项与坑

1. **不要用 Windows 盘符路径操作 WSL 内文件**。WSL 里 `/mnt/c/...` 对应 `C:\...`。
2. **项目仓库必须在 WSL 原生路径（`~/`）**，不要放在 `/mnt/*` 下编译（9p 协议极慢）。
3. **路径不能包含中文或非 ASCII 字符**：Dart analysis server（`flutter analyze`）在路径含中文时会崩溃（`FormatException: Unterminated string`）。E 盘的 `轻读` 目录名就触发了这个问题。仓库必须复制到纯 ASCII 路径（如 `~/projects/fqapp-src`）后才能跑分析和构建。E 盘备份包仅用于文件搬运，不在此路径下直接开发。
4. **Flutter wrapper 的坑**：如果 shell 命中 `/mnt/d/.../Flutter` 的 Windows 版并报 `$'\r'`，把 `$HOME/flutter/bin` 前置到 `PATH`：
   ```bash
   export PATH=$HOME/flutter/bin:$PATH
   ```
5. **签名材料不要提交进 Git**。`android/keystore.properties` 和 `*.jks` 均已加入 `.gitignore`。
6. **`android/local.properties` 会被 Flutter 自动生成**，但新电脑上的路径不同，首次 `flutter pub get` 会覆盖。
7. **JNI 库是 git 忽略的**。如果换电脑后 `flutter test` 跳过 Rust 集成测试，是因为缺少 `.so`，用预编译库或重编即可。
8. **Rust 构建需要 NDK**。交叉编译命令在 `scripts/build_rust_backend.sh` 中。

---

## 八、版本号与发布流程

- 版本号在 `pubspec.yaml` 的 `version:` 一处维护（当前 `1.0.131+136`）。
- 改版本号后需要同步更新 `android/local.properties`（Flutter 会自动覆盖）。
- 发布前先跑 `flutter analyze` 和 `flutter test`。
- 构建产物用 `python3 scripts/verify_android_apk.py` 校验签名、ABI、对齐。

---

## 九、项目文档索引

以下文档在 Git 仓库内，克隆后即可查看：

| 文件 | 内容 |
| --- | --- |
| `README.md` | 项目简介、构建说明、验证命令 |
| `AGENT-HANDOVER-NEXT.md` | 最新交接状态（本批次 UI 动画） |
| `AGENT-HANDOVER.md` | 历史总交接（功能背景） |
| `QINGDU-CHANGES.md` | 变更日志 |
| `AGENTS.md` | AI 代理工作规范 |
| `scripts/README.md` | 构建与维护脚本说明 |

**注**：`docs/` 文件夹被 `.gitignore` 忽略（含研究记录），本备份不含此内容。如新电脑上需要查阅历史研究文档，需从原电脑 `~/projects/fqapp-src/docs/` 单独拷贝。

---

## 十、快速参考卡

```bash
# 依赖
flutter pub get --enforce-lockfile

# 静态分析
flutter analyze

# 全量测试
flutter test

# 构建 release APK
flutter build apk --release --target-platform android-arm64

# 推送
git push origin master

# 验证远端
git ls-remote --heads origin master
```
