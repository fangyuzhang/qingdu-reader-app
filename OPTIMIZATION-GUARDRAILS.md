# OPTIMIZATION-GUARDRAILS.md — 本次瘦身重构的自我约束清单

> 依据 README.md「界面与交互约定」、AGENTS.md「项目与技术基线」、DEVELOPMENT.md「必须保持」、AGENT-HANDOVER-NEXT.md。
> 每一波改动前逐条自查；任何优化机会与本文冲突 → 放弃并记录。

## 1. 技术版本锁

- Flutter **3.47.7 stable**（Dart 3.13.5）；pubspec SDK 约束 `^3.12.2` 不动。
- flutter_rust_bridge 的 Rust crate / Dart 包 / codegen **统一固定 2.13.0**；生成物与生成方式不变（不改 rust/ 与 FRB 生成代码）。
- Android：SDK 36 / NDK 28.2.13676358 / JDK 17 / Gradle 9.1.0，仅 `arm64-v8a`。
- 不顺手升级任何依赖版本；依赖调整仅限"移除未使用项"。

## 2. 架构红线

- Rust 以**进程内库**形式工作（flutter_rust_bridge 调用 fqapi_core），不引入独立后端进程。
- `127.0.0.1:8080` loopback 适配层不得重写（rust/src/、native/ 本次一律不动）。
- 状态存储：Hive CE（LibraryStore 等）+ SharedPreferences + Android Keystore（flutter_secure_storage）方案不替换。
- 分层：Widget 不写 IO/网络/数据库；新组件只进 UI 层。
- 阅读器：分页与滚动**共用同一高度测量**（禁止两套算法）；批注输入弹层由 StatefulWidget 持有 controller/focus；正文背景/分页/滚动/书签/进度逻辑零改动。
- 听书：完成/失败/切章事件按播放代数过滤迟到回调的逻辑不动。

## 3. 界面与交互约定（README.md 原文条目，逐条有效）

1. 首页不设滚动悬浮搜索按钮；搜索只保留固定顶栏入口。
2. 分类卡不写「精选 N 本」；统一「精选书单 · 查看全部」。
3. 横向书架「滑到底再滑」= 查看全部（过冲约 36dp 触发 + 轻震动；v48 已由 72dp 下调，以现值为准）。
4. 可点区域 ≥ 48dp（视觉尺寸可以小，命中区必须补足）。
5. 小字号文字对比度 ≥ 4.5:1（次要文字 #5E6B64=5.37:1，强调小字 #176B58=6.16:1，阅读器辅助文字用正文色 80% 透明度）。
6. 工具栏覆盖正文，不挤压正文；仅第一页允许留出顶部安全区。
7. 正文沉浸态与系统栏联动（收起→隐藏；展开→恢复；退出阅读页恢复）。
8. 全应用锁竖屏（main.dart + MainActivity 双保险）。
9. 全局日夜与阅读器背景同源。

## 4. 数据层

- Hive CE / SharedPreferences / Keystore 安全存储方案不替换；box key 与迁移逻辑不动。
- 番茄账号导入只读；不新增账号写操作。

## 5. 构建产物

- 仅 arm64-v8a；Native 库与 zip 条目 16 KiB 对齐；签名与验证脚本流程不变。
- `scripts/verify_android_apk.py` 校验项不得因本次改动而变化。

## 6. 禁止行为

- 不引入新的状态管理库 / 路由库 / UI 框架 / logger 包。
- 不删除测试；不为通过测试修改断言。
- 不修改 analysis_options.yaml 绕过警告。
- 不重命名 public 类；不改动 part/export 关系。
- 不恢复任何已裁撤功能（短剧/漫剧/漫画/悬浮搜索按钮等）。
- 不动 rust/、native/、android/ 的构建与协议代码。
- 遵守 AGENTS.md：构建、测试、Git 提交串行；不顺手升级依赖。

## 7. 验证门槛（每小步）

- `flutter analyze`：0 error / 0 warning / 0 info（在 ASCII 路径构建副本执行，基线为 0）。
- 全量 `flutter test`：1511 通过 / 10 跳过 / 0 失败（基线）。
- 任一失败：两轮修复无效 → `git checkout -- <涉及文件>` 回滚该小步并记录。
