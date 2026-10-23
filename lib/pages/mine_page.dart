import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/app_theme.dart';
import '../widgets/home/home_design.dart';
import 'about_page.dart';
import 'cached_books_page.dart';
import 'notes_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

/// 个人中心（我的）页：顶部书友卡片 + 快捷入口（章节缓存/设置/关于）
/// + 嵌入式阅读与视听统计。
class MinePage extends StatelessWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = HomePalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('我的'),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          // 【青茄·日夜切换】放在设置左侧：一键在深色 / 亮色之间切换，
          // 与设置页「外观」、阅读页夜间按钮写的是同一个全局偏好。
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              final dark = einkModeNotifier.value
                  ? false
                  : themeModeIsDark(mode, MediaQuery.platformBrightnessOf(context));
              return IconButton(
                icon: Icon(dark ? LucideIcons.sun : LucideIcons.moon),
                tooltip: dark ? '切换到亮色' : '切换到深色',
                onPressed: () => unawaited(
                  setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(LucideIcons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: StatsPage(header: _buildProfileHeader(context, scheme, palette)),
    );
  }

  Widget _buildProfileHeader(
    BuildContext context,
    ColorScheme scheme,
    HomePalette palette,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 个人概览卡片
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2FA98C), Color(0xFF1F8A72)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: HomePalette.accent.withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  LucideIcons.circle_user_round,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '书友',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '沉浸阅读，记录每一个好故事',
                      style: TextStyle(fontSize: 12.5, color: palette.muted),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: palette.line, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.sliders_horizontal,
                        size: 13,
                        color: palette.accentText,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: palette.accentText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 【青茄重构·新增】快捷入口：笔记（批注/书摘） + 缓存 + 设置 + 关于
        Row(
          children: [
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.pen_line,
              label: '笔记',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotesPage()),
              ),
            ),
            const SizedBox(width: 8),
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.bookmark,
              label: '章节缓存',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CachedBooksPage()),
              ),
            ),
            const SizedBox(width: 8),
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.sliders_horizontal,
              label: '应用设置',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
            ),
            const SizedBox(width: 8),
            _buildShortcutTile(
              context: context,
              icon: LucideIcons.info,
              label: '关于我们',
              palette: palette,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Container(
              width: 3.5,
              height: 14,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: HomePalette.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              '阅读与视听统计',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 快捷入口沿用听书页的「同一主色、深浅分层」：底色 soft、图标底 accent@14%，
  /// 靠图标形状和文字区分入口，不再各给一个彩色，视线不会被四块颜色拉扯。
  Widget _buildShortcutTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required HomePalette palette,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: palette.soft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          splashColor: HomePalette.accent.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: HomePalette.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 18, color: palette.accentText),
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
