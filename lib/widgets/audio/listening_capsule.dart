import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// 听书迷你胶囊：悬浮在任意页面之上，可拖动，只保留最少的信息与操作。
///
/// 旧版底部通栏播放条占满一整行、还会顶起页面内容；正文阅读时它把阅读区
/// 挤窄了一块。这里改成一颗药丸形胶囊：播放/暂停、听书设置、关闭三颗按钮
/// 加一行标题，位置由调用方（[AudioPlaybackScope]）接管拖动与吸附。
class ListeningCapsule extends StatelessWidget {
  const ListeningCapsule({
    super.key,
    required this.title,
    required this.playing,
    required this.onOpen,
    required this.onToggle,
    required this.onSettings,
    required this.onClose,
    this.status,
  });

  /// 一行书名或章节名，超出省略。
  final String title;

  /// 详情或状态行（例如「正在加载…」「系统朗读 · 第 3 章」）。
  final String? status;

  final bool playing;
  final VoidCallback onOpen;
  final VoidCallback? onToggle;
  final VoidCallback onSettings;
  final VoidCallback onClose;

  static const width = 232.0;
  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final text = status == null || status!.isEmpty ? title : '$title · $status';
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          // 浮在正文之上：底色抬一层（soft 比 canvas 更亮/更深），再压一圈
          // 描边和阴影，深色阅读背景上也能一眼看出是独立控件。
          color: palette.soft,
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: palette.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: palette.dark ? 0.55 : 0.16),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 4),
            _CapsuleButton(
              buttonKey: const ValueKey('audio-mini-toggle'),
              icon: playing ? LucideIcons.pause : LucideIcons.play,
              tooltip: playing ? '暂停听书' : '继续听书',
              onPressed: onToggle,
            ),
            Expanded(
              child: InkWell(
                key: const ValueKey('audio-mini-open'),
                onTap: onOpen,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            _CapsuleButton(
              buttonKey: const ValueKey('audio-mini-settings'),
              icon: LucideIcons.sliders_horizontal,
              tooltip: '听书设置',
              onPressed: onSettings,
            ),
            _CapsuleButton(
              buttonKey: const ValueKey('audio-mini-close'),
              icon: LucideIcons.x,
              tooltip: '关闭听书',
              onPressed: onClose,
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      style: IconButton.styleFrom(foregroundColor: palette.ink),
      icon: Icon(icon),
    );
  }
}
