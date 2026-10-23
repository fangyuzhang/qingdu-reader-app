import 'package:flutter/material.dart';

import '../services/system_tts.dart';
import '../widgets/home/home_design.dart';

class SystemTtsSettingsPage extends StatefulWidget {
  const SystemTtsSettingsPage({super.key});

  @override
  State<SystemTtsSettingsPage> createState() => _SystemTtsSettingsPageState();
}

class _SystemTtsSettingsPageState extends State<SystemTtsSettingsPage>
    with WidgetsBindingObserver {
  List<SystemTtsEngine> _engines = const [];
  String? _defaultEngine;
  SystemTtsPreferences _prefs = const SystemTtsPreferences();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_saving) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SystemTtsPreferences.load();
      final data = await SystemTts.engines();
      if (!mounted || generation != _generation) return;
      setState(() {
        _prefs = prefs;
        _engines = data.engines;
        _defaultEngine = data.defaultEngine;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = SystemTts.errorMessage(e);
      });
    }
  }

  Future<void> _save(SystemTtsPreferences prefs) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await prefs.save();
      if (mounted) setState(() => _prefs = prefs);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSettings() async {
    try {
      await SystemTts.openSettings();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(SystemTts.errorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedMissing =
        _prefs.engine != null &&
        !_engines.any((e) => e.package == _prefs.engine);
    final defaultLabel = _engines
        .where((e) => e.package == _defaultEngine)
        .firstOrNull
        ?.label;
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('系统朗读'),
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '从小说或本地书阅读页点“听书”即可使用。支持已安装的系统 TTS 引擎，例如 MultiTTS；音色和联网需求由引擎管理。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: palette.muted,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: palette.muted),
                          ),
                        ),
                        TextButton(
                          onPressed: _load,
                          style: TextButton.styleFrom(
                            foregroundColor: palette.accentText,
                          ),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                else if (_engines.isEmpty)
                  Text(
                    '没有找到朗读引擎，请先安装并在引擎应用中配置中文语音。',
                    style: TextStyle(color: palette.muted, height: 1.6),
                  )
                else
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: palette.line, width: 0.6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (selectedMissing)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              '之前选择的引擎已不可用，请重新选择。',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.accentText,
                              ),
                            ),
                          ),
                        DropdownButtonFormField<String>(
                          key: ValueKey(_prefs.engine ?? ''),
                          initialValue: selectedMissing
                              ? null
                              : (_prefs.engine ?? ''),
                          decoration: InputDecoration(
                            labelText: '朗读引擎',
                            labelStyle: TextStyle(color: palette.muted),
                            filled: true,
                            fillColor: palette.soft,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: palette.line,
                                width: 0.6,
                              ),
                            ),
                          ),
                          dropdownColor: palette.surface,
                          style: TextStyle(fontSize: 14, color: palette.ink),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(
                                '系统默认${defaultLabel == null ? '' : ' · $defaultLabel'}',
                                style: TextStyle(color: palette.ink),
                              ),
                            ),
                            for (final engine in _engines)
                              DropdownMenuItem(
                                value: engine.package,
                                child: Text(
                                  engine.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: palette.ink),
                                ),
                              ),
                          ],
                          isExpanded: true,
                          onChanged: _saving
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  _save(
                                    SystemTtsPreferences(
                                      engine: value.isEmpty ? null : value,
                                      rate: _prefs.rate,
                                    ),
                                  );
                                },
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Text(
                              '语速',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: palette.ink,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: HomePalette.accent.withValues(
                                  alpha: 0.14,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_prefs.rate.toStringAsFixed(1)}×',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: HomePalette.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: HomePalette.accent,
                            inactiveTrackColor: palette.line,
                            thumbColor: HomePalette.accent,
                            overlayColor: HomePalette.accent.withValues(
                              alpha: 0.12,
                            ),
                            valueIndicatorColor: palette.surface,
                            valueIndicatorTextStyle: TextStyle(
                              color: palette.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: Slider(
                            value: _prefs.rate,
                            min: 0.5,
                            max: 2,
                            divisions: 15,
                            label: '${_prefs.rate.toStringAsFixed(1)}×',
                            onChanged: _saving
                                ? null
                                : (value) => setState(() {
                                    _prefs = SystemTtsPreferences(
                                      engine: _prefs.engine,
                                      rate: value,
                                    );
                                  }),
                            onChangeEnd: _saving
                                ? null
                                : (value) => _save(
                                    SystemTtsPreferences(
                                      engine: _prefs.engine,
                                      rate: value,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  '引擎和语速修改在关闭当前系统朗读、重新开始后生效。部分引擎暂停后会从当前短句重读。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _openSettings,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.accentText,
                    side: BorderSide(
                      color: palette.accentText.withValues(alpha: 0.4),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.settings_voice, size: 18),
                  label: const Text('打开系统语音设置'),
                ),
              ],
            ),
    );
  }
}
