# Pencil Engine（早期官方手写接口）接入指南与现状

> 背景：MatePad 11 (2021) + M-Pencil 3，HarmonyOS 2-4（非 NEXT）。项目为 Flutter Android APK。
> 本文档记录「阶段三优先路径（早期官方 Pencil Engine）」的检索结论、当前未接入的确切原因、以及真机到位后的接入步骤。

## 1. 检索结论（2026-10-26，检索 agent 带来源核验）

- **Pencil Engine 对第三方 APK 开放**：以 HMS Core Android SDK 形式发布（包 `com.huawei.stylus.penengine`，核心类 `HwPenEngine`），官方明确支持 **HarmonyOS 2.0+** 设备（即在 MatePad 11 的 Android 兼容层上可跑）。
  - 来源：华为开发者联盟 HMS 手写笔能力页（`developer.huawei.com/consumer/cn/hms/huawei-pencilengine`，支持平台=Android）；官方指南《手写套件功能》（"编译出的 APK …"，`connectivity-Guides/handwriting-suite-function-0000001059327099`）；API 参考 `connectivity-References/overview-0000001060193728`（HwPenEngine 使能接口）。
- **HandwriteComponent / @kit.Penkit 不可用**：起始版本 5.0.0(12) = HarmonyOS NEXT 首个基线；MatePad 11 (2021) 最高 HarmonyOS 4（API 10/11）< 12，且本项目不是 HAP 工程。**按任务约束禁止集成。**
- **StylusFrameBoost 不可用**：API 26 起步（NEXT 远期），禁止作为依据。
- **M-Pencil 在普通 APK 侧的呈现**：标准 Android stylus（压感 0~1 可用，多方实测印证）；tilt 轴可用性「因应用而异」（低-中置信）；双击手势以非标键码（keycode 718）送达。

## 2. 当前未接入 Pencil Engine 的确切原因

**构建网络无法访问华为 Maven 仓库**：`https://developer.huawei.com/repo/` 对本机出口返回 HTML 闸页/404（连已知的 HMS 坐标 `com.huawei.hms:hihealth` 的 maven-metadata.xml 都取不到）→ 闭源 AAR 无法解析下载，`implementation` 无法编译。无公开镜像（MVNRepository/Maven Central 均无 `com.huawei.stylus` 索引）。

## 3. 现行方案（阶段三第 2 条：自定义 Canvas 渲染）

**当前方案为非官方组件的自定义渲染，用于兼容低于 API 12 的 HarmonyOS 版本，开发与维护成本由应用侧承担。**

已实现（含 78 批增强）：
- 笔/手指区分：PointerDeviceKind.stylus 直书；手指 pan 在画布内书写、画布外滚动翻页；
- 压感宽度：`宽 = base × (0.35 + 0.65×pressure)`；
- 倾斜侧锋（78 批）：`× (1 + 0.6×tilt)`，M-Pencil 3 放平书写最多加粗 60%；手指/旧存档 tilt=0 行为与旧版完全一致；
- 轨迹平滑：中点二次贝塞尔；
- 预测笔尖（78 批）：最近两点速度外推 ≤10dp 的视觉段补偿输入间隔（非系统级报点预测），不写入笔迹数据；
- 探测页：stylus_probe_page 实测 kind/pressure/tilt/orientation（M-Pencil 到位后直接读取）。

## 4. 真机到位后的 Pencil Engine 接入步骤（按优先级）

1. 构建环境可访问 `developer.huawei.com/repo/` 后（或手动下载 AAR 放 libs/）：
   - settings.gradle.kts 仓库加 `maven { url = uri("https://developer.huawei.com/repo/") }`；
   - 依赖坐标从官方「集成准备」页取（公网无索引，勿凭记忆猜版本）；
2. Kotlin 侧运行时探测：`Class.forName("com.huawei.stylus.penengine.HwPenEngine")` + 官方使能接口判断设备支持；**失败一律静默降级到现行自研渲染**（本文件 §3 路径永不删除）；
3. 只桥接两类能力，笔迹数据与存储仍走自研模型（InkPoint/InkStroke/锚定）：
   - 报点预测：predicted point 仅并入 painter 的 live 渲染（与 §3 预测笔尖同层），**不入库**；
   - 双击切工具：keycode 718 → 触发 橡皮/笔 切换（VolumeKeyService 同款拦截模式可参考）；
4. 验证：MatePad 真机 logcat 确认探测分支 + 书写延迟对比（有无 predicted 桥）。

## 5. 约束遵守记录

- 未修改任何华为官方接口定义/行为（未接入即无从修改）；
- 版本判定先行：项目无鸿蒙工程结构（Android APK，compileSdk/targetSdk 36、minSdk 24，Android 体系），目标设备 API < 12 → 未导入 `@kit.Penkit`、未声明 HandwriteComponent、未引用 StylusFrameBoost 文档作为依据。
