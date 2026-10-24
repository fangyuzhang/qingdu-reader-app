import 'package:flutter/foundation.dart';

/// 调试工具总开关（手写笔探测页、批注诊断页等）。
///
/// - 普通构建（debug/profile）：可用。
/// - 普通构建（release）：不可用。
/// - 验证用 release 包：`--dart-define=fqapp.debugTools=true` 强制开启，
///   签名与正式包一致，可直接覆盖安装做真机验证，不影响默认发布产物。
const bool debugToolsEnabled =
    kDebugMode || bool.fromEnvironment('fqapp.debugTools');
