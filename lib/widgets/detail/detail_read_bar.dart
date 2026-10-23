import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// Bottom action bar: secondary actions (听书 / 加入书架) on the left and the
/// primary read / play call to action as a filled pill on the right.
class DetailReadBar extends StatelessWidget {
  final String label;
  final String? resumeTitle;
  final IconData icon;
  final bool opening;
  final VoidCallback onRead;

  /// Opens the listening page. Hidden when the work has no audio version.
  final VoidCallback? onListen;

  /// Adds or removes the work from the local shelf.
  final VoidCallback? onShelf;

  /// Whether the work is already on the shelf; switches the icon and label.
  final bool inShelf;

  const DetailReadBar({
    super.key,
    required this.label,
    required this.icon,
    required this.opening,
    required this.onRead,
    this.resumeTitle,
    this.onListen,
    this.onShelf,
    this.inShelf = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final largeType = MediaQuery.textScalerOf(context).scale(16) > 24;
    final secondary = <_Secondary>[
      if (onListen != null)
        (
          icon: LucideIcons.headphones,
          label: '听书',
          keyName: '听书',
          onTap: onListen!,
          emphasized: false,
        ),
      if (onShelf != null)
        (
          icon: inShelf ? LucideIcons.bookmark_check : LucideIcons.bookmark_plus,
          label: inShelf ? '已在书架' : '加入书架',
          keyName: '加入书架',
          onTap: onShelf!,
          emphasized: true,
        ),
    ];
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(
            top: BorderSide(
              color: palette.line,
              width: 0.6,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: palette.dark ? 0.28 : 0.04,
              ),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (resumeTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.clock_arrow_up,
                            size: 13,
                            color: palette.muted,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '上次读到：$resumeTitle',
                              key: const Key('detail_resume_label'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 11,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      for (final action in secondary) ...[
                        _SecondaryAction(
                          icon: action.icon,
                          label: action.label,
                          keyName: action.keyName,
                          onTap: action.onTap,
                          emphasized: action.emphasized,
                          compact: largeType,
                        ),
                        Container(
                          width: 0.5,
                          height: 22,
                          color: palette.line,
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                      ],
                      Expanded(
                        child: Semantics(
                          enabled: !opening,
                          child: IgnorePointer(
                            ignoring: opening,
                            child: HomePressable(
                              key: const Key('detail_read_button'),
                              onTap: onRead,
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 13,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: opening
                                        ? [palette.muted, palette.muted]
                                        : const [
                                            HomePalette.accent,
                                            Color(0xFFE4432E),
                                          ],
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: opening
                                      ? null
                                      : [
                                          BoxShadow(
                                            color: HomePalette.accent
                                                .withValues(alpha: 0.20),
                                            blurRadius: 14,
                                            offset: const Offset(0, 5),
                                          ),
                                        ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (!largeType) ...[
                                      if (opening)
                                        const SizedBox.square(
                                          dimension: 17,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      else
                                        Icon(
                                          icon,
                                          color: Colors.white,
                                          size: 19,
                                        ),
                                      const SizedBox(width: 8),
                                    ],
                                    Flexible(
                                      child: Text(
                                        opening ? '正在打开' : label,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w700,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
}

class _SecondaryAction extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Stable identifier for the widget key; the label may change (e.g. 加入书架
  /// vs 已在书架) while the key stays the same.
  final String keyName;
  final VoidCallback onTap;
  final bool compact;

  /// 加入书架 is the primary secondary action, so it gets a slightly larger
  /// icon, label and horizontal padding.
  final bool emphasized;

  const _SecondaryAction({
    required this.icon,
    required this.label,
    required this.keyName,
    required this.onTap,
    required this.compact,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      key: Key('detail_action_$keyName'),
      semanticLabel: label,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: emphasized ? 8 : 4,
          vertical: emphasized ? 4 : 6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: emphasized ? 22 : 19, color: palette.ink),
            if (!compact) ...[
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: emphasized ? 11.5 : 10.5,
                  height: 1.25,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A secondary action: what it shows and what it opens.
typedef _Secondary = ({
  IconData icon,
  String label,
  String keyName,
  VoidCallback onTap,
  bool emphasized,
});
