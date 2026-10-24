import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';


/// Persisted theme-mode preference key: 'theme_mode' = 'light'|'dark'|'system'.
const themeModeKey = 'theme_mode';

/// Global theme-mode notifier; the settings page writes it, MaterialApp
/// rebuilds with the new mode.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.system,
);

/// Persisted e-ink mode key: 'eink_mode' = bool.
/// #15/#9：墨水屏模式。开启时全应用纯黑白、无毛玻璃、无过渡动画，
/// 避免墨水屏量化灰阶 / 残影。关闭后恢复原主题。
const einkModeKey = 'eink_mode';

/// Global e-ink mode notifier; the settings page writes it, MaterialApp
/// rebuilds with the e-ink theme.
final ValueNotifier<bool> einkModeNotifier = ValueNotifier(false);

/// No page transition: e-ink screens ghost on every animated frame, so
/// route changes must swap instantly instead of sliding / fading.
class _NoPageTransitionBuilder extends PageTransitionsBuilder {
  const _NoPageTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// Resolves [mode] against the current platform brightness. `system` follows the
/// device setting; everything else answers for itself.
bool themeModeIsDark(ThemeMode mode, Brightness platformBrightness) =>
    switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };

/// Writes the global theme mode and persists it, so the reader's night button
/// and the settings / 我的 switches all drive the same preference.
Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(themeModeKey, mode.name);
  } catch (_) {
    // 保存失败不影响当前会话的显示，下次启动退回系统默认。
  }
}

ThemeMode themeModeFromName(String? name) {
  switch (name) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

/// 墨水屏纯黑白配色。
///
/// 全局主题（`AppTheme`）与阅读页正文主题（`ReaderThemePreset.theme`）取同一份，
/// 避免同一组颜色抄两遍、改一处漏一处。
const einkColorScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Colors.black,
  onPrimary: Colors.white,
  primaryContainer: Colors.white,
  onPrimaryContainer: Colors.black,
  secondary: Colors.black,
  onSecondary: Colors.white,
  secondaryContainer: Colors.white,
  onSecondaryContainer: Colors.black,
  tertiary: Colors.black,
  onTertiary: Colors.white,
  surface: Colors.white,
  onSurface: Colors.black,
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Colors.white,
  surfaceContainer: Colors.white,
  surfaceContainerHigh: Colors.white,
  surfaceContainerHighest: Colors.white,
  onSurfaceVariant: Colors.black,
  outline: Colors.black,
  outlineVariant: Colors.black,
  error: Colors.black,
  onError: Colors.white,
  errorContainer: Colors.white,
  onErrorContainer: Colors.black,
);

/// Unified design system and theme factory for fqapp.
class AppTheme {
  static const Color accent = Color(0xFF2FA98C);
  static const Color accentStrong = Color(0xFF1F8A72);
  static const Color accentDark = Color(0xFF4FC3A4);

  /// 点缀色（重点标记、15+ 标签、收藏态）。
  static const Color highlight = Color(0xFFE2603F);

  /// Pure black-on-white theme for e-ink (#15/#9). No tonal / seed palette,
  /// no grey scale except black-on-white, no ripple, no page transition.
  /// Dark mode is intentionally not honoured here: inverted e-ink pages
  /// ghost badly and the issue asks for #FFFFFF surface / #000000 text.
  static ThemeData _createEinkTheme() {
    const scheme = einkColorScheme;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _NoPageTransitionBuilder(),
          TargetPlatform.iOS: _NoPageTransitionBuilder(),
          TargetPlatform.macOS: _NoPageTransitionBuilder(),
          TargetPlatform.windows: _NoPageTransitionBuilder(),
          TargetPlatform.linux: _NoPageTransitionBuilder(),
          TargetPlatform.fuchsia: _NoPageTransitionBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Colors.black,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(size: 22, color: Colors.black),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.black, width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: Colors.black, width: 0.6),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        contentTextStyle: const TextStyle(
          fontSize: 14,
          color: Colors.black,
          height: 1.4,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        modalBackgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        dragHandleColor: Colors.black,
        dragHandleSize: Size(36, 4),
      ),
      dividerTheme: const DividerThemeData(
        color: Colors.black,
        thickness: 0.6,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        dense: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Colors.black,
        ),
        subtitleTextStyle: TextStyle(fontSize: 12.5, color: Colors.black),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: Colors.black,
        contentTextStyle: const TextStyle(fontSize: 13, color: Colors.white),
      ),
    );
  }

  static ThemeData createTheme(Brightness brightness, {bool einkMode = false}) {
    if (einkMode) return _createEinkTheme();
    final isDark = brightness == Brightness.dark;
    final primary = isDark ? accentDark : accent;
    final canvas = isDark ? const Color(0xFF0F1413) : const Color(0xFFFAFBF6);
    final surface = isDark ? const Color(0xFF171E1C) : Colors.white;
    final surfaceContainerLow = isDark
        ? const Color(0xFF141B19)
        : const Color(0xFFF4F7F1);
    final surfaceContainer = isDark
        ? const Color(0xFF1B2421)
        : const Color(0xFFEEF3EC);
    final surfaceContainerHigh = isDark
        ? const Color(0xFF232D2A)
        : const Color(0xFFE6EDE4);
    final ink = isDark ? const Color(0xFFF1F5F2) : const Color(0xFF212824);
    // 浅色 #6C7A73 在 canvas(#FAFBF6) 上只有 4.33:1，ListTile 副标题
    // (12.5sp) 与 onSurfaceVariant 图标都压线；与 HomePalette.muted 统一
    // 到 #5E6B64(5.37:1)。
    final muted = isDark ? const Color(0xFF98A5A0) : const Color(0xFF5E6B64);
    final line = isDark ? const Color(0xFF2A3330) : const Color(0xFFE3E9E1);

    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: isDark
          ? const Color(0xFF123B30)
          : const Color(0xFFD9F2E8),
      onPrimaryContainer: isDark
          ? const Color(0xFFB8EEDC)
          : const Color(0xFF00382B),
      secondary: isDark ? const Color(0xFFFF8A6B) : const Color(0xFFE2603F),
      onSecondary: Colors.white,
      secondaryContainer: isDark
          ? const Color(0xFF3B1E14)
          : const Color(0xFFFFE6DE),
      onSecondaryContainer: isDark
          ? const Color(0xFFFFD9CC)
          : const Color(0xFF3F1509),
      tertiary: isDark ? const Color(0xFF7DB3EC) : const Color(0xFF4A90D9),
      onTertiary: Colors.white,
      surface: surface,
      onSurface: ink,
      surfaceContainerLowest: isDark ? const Color(0xFF0B100F) : Colors.white,
      surfaceContainerLow: surfaceContainerLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest: isDark
          ? const Color(0xFF2E3A36)
          : const Color(0xFFDDE6DA),
      onSurfaceVariant: muted,
      outline: isDark ? const Color(0xFF6F7D77) : const Color(0xFF97A39C),
      outlineVariant: line,
      error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
      onError: isDark ? const Color(0xFF690005) : Colors.white,
      errorContainer: isDark
          ? const Color(0xFF93000A)
          : const Color(0xFFFFDAD6),
      onErrorContainer: isDark
          ? const Color(0xFFFFDAD6)
          : const Color(0xFF410002),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(size: 22, color: ink),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: line, width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: line, width: 0.6),
        ),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        contentTextStyle: TextStyle(fontSize: 14, color: muted, height: 1.4),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        dragHandleColor: line,
        dragHandleSize: const Size(36, 4),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 0.6, space: 1),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        dense: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: ink,
        ),
        subtitleTextStyle: TextStyle(fontSize: 12.5, color: muted),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: isDark
            ? const Color(0xFF2C2C30)
            : const Color(0xFF2C2825),
        contentTextStyle: const TextStyle(fontSize: 13, color: Colors.white),
      ),
    );
  }
}
