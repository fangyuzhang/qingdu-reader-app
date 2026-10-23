import 'package:flutter/material.dart';

import '../services/app_theme.dart';

/// App-wide dialog entrance: 180ms fade + slight upward slide.
///
/// Material's default DialogRoute fades and scales. A small slide reads calmer
/// on the paper-like surfaces used here, and FadeTransition/SlideTransition
/// keep the animation on the compositor. E-ink and reduced-motion users get an
/// instant swap.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final mediaQuery = MediaQuery.of(context);
  final textDirection = Directionality.of(context);
  final instant =
      einkModeNotifier.value || MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    barrierLabel:
        barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor ?? Colors.black54,
    routeSettings: routeSettings,
    transitionDuration:
        instant ? Duration.zero : const Duration(milliseconds: 180),
    pageBuilder: (routeContext, animation, secondaryAnimation) {
      Widget dialog = themes.wrap(Builder(builder: builder));
      if (useSafeArea) dialog = SafeArea(child: dialog);
      return Directionality(
        textDirection: textDirection,
        child: MediaQuery(data: mediaQuery, child: dialog),
      );
    },
    transitionBuilder: (routeContext, animation, secondaryAnimation, child) {
      final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.035),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
