import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/app_theme.dart';
import '../services/audio_preferences.dart';
import '../services/backend_service.dart';
import '../services/debug_tools.dart';
import '../services/library_store.dart';
import '../widgets/app_dialog.dart';
import '../widgets/home/home_design.dart';
import 'about_page.dart';
import 'annotation_diagnostics_page.dart';
import 'cached_books_page.dart';
import 'library_backup_page.dart';
import 'log_viewer_page.dart';
import 'settings_category_page.dart';
import 'stylus_probe_page.dart';
import 'system_tts_settings_page.dart';

/// Settings home: a list of category entries (PiliPlus multi-level
/// navigation). Each category opens its own CommonSetting-style page.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final categories = <SettingsCategory>[
      SettingsCategory(
        icon: LucideIcons.palette,
        title: '外观',
        subtitle: '深色模式、墨水屏模式',
        items: [_themeModeItem(), _einkModeItem()],
      ),
      SettingsCategory(
        icon: LucideIcons.headphones,
        title: '听书',
        subtitle: '后台播放、通知栏控制与系统朗读',
        items: [
          _backgroundAudioItem(),
          SettingsItem(
            icon: LucideIcons.mic,
            title: '系统朗读',
            subtitle: '选择 TTS 引擎与语速，支持本地书',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.database,
        title: '数据',
        subtitle: '备份与恢复、缓存、阅读与收听历史',
        items: [
          SettingsItem(
            icon: LucideIcons.database,
            title: '备份与导入',
            subtitle: '本机备份、恢复与番茄书架导入',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LibraryBackupPage()),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.bookmark,
            title: '章节缓存',
            subtitle: '离线续读、查看占用和清理缓存',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedBooksPage()),
            ),
          ),
          _clearHistItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.cpu,
        title: '服务',
        subtitle: '本地后端状态',
        items: [
          // 调试工具：见 services/debug_tools.dart 的开关说明。
          if (debugToolsEnabled) _inkDiagnosticsItem(),
          if (debugToolsEnabled) _stylusProbeItem(),
          _backendItem(),
          _statusItem(),
          _logItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.info,
        title: '关于',
        subtitle: '版本与应用信息',
        pageBuilder: (_) => const AboutPage(),
        items: const [],
      ),
    ];

    // 分类底色跟着品牌走：默认青茄绿，听书用珊瑚橙点一下（品牌另一半），
    // 服务/关于这类系统项退到 muted，形成层级而不是六种颜色互相抢。
    Color tintOf(SettingsCategory category) => switch (category.title) {
      '听书' => HomePalette.highlight,
      '服务' || '关于' => palette.muted,
      _ => HomePalette.accent,
    };

    return SettingsScaffold(
      title: '设置',
      children: [
        for (final cat in categories)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: tintOf(cat).withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(cat.icon, size: 19, color: tintOf(cat)),
            ),
            title: Text(
              cat.title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: palette.ink,
              ),
            ),
            subtitle: Text(
              cat.subtitle,
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
            trailing: Icon(
              LucideIcons.chevron_right,
              size: 18,
              color: palette.muted,
            ),
            onTap: () {
              final pageBuilder = cat.pageBuilder;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      pageBuilder ??
                      (_) => SettingsCategoryPage(
                        title: cat.title,
                        items: cat.items,
                      ),
                ),
              );
            },
          ),
      ],
    );
  }

  // ── 外观 ──────────────────────────────────────────────────────────────

  SettingsItem _themeModeItem() => SettingsItem(
    icon: LucideIcons.sun_moon,
    title: '深色模式',
    trailingBuilder: (context) => ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _modeLabel(mode),
            // outline 是描边色（#97A39C 在浅底上只有 2.5:1），不能当文字用。
            style: TextStyle(color: HomePalette.of(context).muted),
          ),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevron_right, size: 18),
        ],
      ),
    ),
    onTap: (context, setState) => _showThemeModeDialog(context),
  );

  String _modeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  Future<void> _showThemeModeDialog(BuildContext context) async {
    final selected = await showAppDialog<ThemeMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('深色模式'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: themeModeNotifier.value,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in const [
                  ThemeMode.system,
                  ThemeMode.light,
                  ThemeMode.dark,
                ])
                  RadioListTile<ThemeMode>(
                    value: m,
                    title: Text(_modeLabel(m)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    themeModeNotifier.value = selected;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!await sp.setString(themeModeKey, selected.name)) {
        throw StateError('Theme preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('外观已更新，但未能保存')));
      }
    }
  }

  /// #15/#9 墨水屏模式：纯黑白、无毛玻璃、无过渡动画。开启时强制浅色，
  /// 深色模式恢复后仍按原设置生效。
  SettingsItem _einkModeItem() => SettingsItem(
    icon: LucideIcons.book_open,
    title: '墨水屏模式',
    subtitle: '纯黑白、无毛玻璃、无过渡动画，适合墨水屏设备',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: einkModeNotifier,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) => unawaited(_setEinkMode(context, v)),
      ),
    ),
    onTap: (context, setState) {
      unawaited(_setEinkMode(context, !einkModeNotifier.value));
    },
  );

  Future<void> _setEinkMode(BuildContext context, bool value) async {
    einkModeNotifier.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!await sp.setBool(einkModeKey, value)) {
        throw StateError('E-ink preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('墨水屏模式已更新，但未能保存')));
      }
    }
  }

  // ── 听书 ──────────────────────────────────────────────────────────────

  SettingsItem _backgroundAudioItem() => SettingsItem(
    icon: LucideIcons.radio,
    title: '后台听书与保活',
    subtitle: '切到后台或锁屏时继续播放，并在通知栏常驻控制卡片',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: AudioPreferences.instance.backgroundPlayback,
      builder: (context, value, _) => Switch(
        value: value,
        onChanged: (v) =>
            unawaited(AudioPreferences.instance.setBackgroundPlayback(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = AudioPreferences.instance.backgroundPlayback.value;
      unawaited(AudioPreferences.instance.setBackgroundPlayback(!current));
    },
  );

  SettingsItem _clearHistItem() => SettingsItem(
    icon: LucideIcons.trash,
    title: '清空历史',
    subtitle: '删除全部阅读/收听历史与累计时长',
    onTap: (context, setState) => _confirmClear(
      context,
      '清空历史',
      '确定清空全部阅读/收听历史与累计时长吗？',
      LibraryStore.instance.clearReadingData,
    ),
  );

  Future<void> _confirmClear(
    BuildContext context,
    String title,
    String message,
    Future<void> Function() action,
  ) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await action();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已清空')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清空失败，请重试')));
      }
    }
  }

  // ── 服务 ──────────────────────────────────────────────────────────────

  SettingsItem _backendItem() => SettingsItem(
    icon: LucideIcons.cpu,
    title: '本地后端',
    subtitle: BackendService.instance.baseUrl,
    // The adapter only answers a request that carries the per-launch
    // capability, and the entry URL is what hands it to a browser as a session
    // cookie. Opening the bare base URL would just land on a 401.
    onTap: (context, setState) => _openWebUi(context),
  );

  /// Opens the built-in Web UI in a browser.
  ///
  /// The transport's `resourceBase` carries the loopback capability in its
  /// path; the adapter answers that entry with a redirect to `/` plus the
  /// session cookie, so the capability never lingers in the address bar.
  Future<void> _openWebUi(BuildContext context) async {
    final entry = BackendService.instance.webUiEntryUrl;
    if (entry.isEmpty) return;
    var launched = false;
    try {
      // Android package visibility may hide a browser from canLaunchUrl even
      // though it can handle the actual ACTION_VIEW intent.
      launched = await launchUrl(
        Uri.parse(entry),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Report launch failures through the same visible fallback.
    }
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开 Web UI')));
    }
  }

  SettingsItem _inkDiagnosticsItem() => SettingsItem(
    icon: LucideIcons.signature,
    title: '批注诊断（调试）',
    subtitle: '查看全部手写批注的锚点状态',
    onTap: (context, setState) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AnnotationDiagnosticsPage()),
    ),
  );

  SettingsItem _stylusProbeItem() => SettingsItem(
    icon: LucideIcons.pen_line,
    title: '手写笔探测（调试）',
    subtitle: '实测压感/倾斜/设备类型，发布前移除',
    onTap: (context, setState) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const StylusProbePage()),
    ),
  );

  SettingsItem _logItem() => SettingsItem(
    icon: LucideIcons.terminal,
    title: '日志',
    subtitle: '查看应用运行日志',
    onTap: (context, setState) => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LogViewerPage()),
    ),
  );

  SettingsItem _statusItem() => SettingsItem(
    icon: LucideIcons.circle_check,
    title: '服务状态',
    rowBuilder: (context) => const _ServiceStatusRow(),
  );

  // ── 关于 ──────────────────────────────────────────────────────────────
  // The About category opens the About page directly via its pageBuilder;
  // no category-page items are needed.
}

/// Self-refreshing service status row (health check + refresh button).
class _ServiceStatusRow extends StatefulWidget {
  const _ServiceStatusRow();

  @override
  State<_ServiceStatusRow> createState() => _ServiceStatusRowState();
}

class _ServiceStatusRowState extends State<_ServiceStatusRow> {
  String _status = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ok = await ApiClient.instance.health();
    if (!mounted) return;
    setState(() => _status = ok ? '运行中' : '已停止');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final healthy = _status == '运行中';
    return ListTile(
      leading: Icon(
        healthy ? LucideIcons.circle_check : LucideIcons.circle_alert,
        // 语义色统一取 ColorScheme：写死 green/red 在深色与墨水屏模式下
        // 既刺眼也和其他状态色不一致；图标仍保留，不只靠颜色传信息。
        color: healthy ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text('服务状态', style: theme.textTheme.titleMedium),
      subtitle: Text(
        _status,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: IconButton(
        icon: const Icon(LucideIcons.rotate_ccw, size: 18),
        onPressed: _refresh,
      ),
    );
  }
}
