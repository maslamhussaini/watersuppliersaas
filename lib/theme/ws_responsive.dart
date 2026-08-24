// =============================================================================
// lib/theme/ws_responsive.dart
// Breakpoints and layout helpers.
//
// WHY THIS EXISTS
// Every screen in this app was written phone-first with edge-to-edge columns.
// That is fine at 400 px and wrong at 1400 px: on a desktop browser the login
// form stretched the full width of the window, with a single text field over a
// metre wide on a large monitor. Nothing was broken, it just looked like a
// prototype.
//
// The rule used throughout: constrain CONTENT width, never the background.
// Colour and surfaces still run edge to edge; text and inputs stay inside a
// readable measure.
// =============================================================================

import 'package:flutter/material.dart';

enum WsScreenSize { mobile, tablet, desktop }

class WsBreakpoints {
  const WsBreakpoints._();

  /// Below this is a phone. Chosen to sit above the largest common phone in
  /// landscape (Pixel 8 Pro is 892 logical px wide) so a landscape phone is
  /// treated as a tablet, which is what its available width warrants.
  static const double tablet = 600;
  static const double desktop = 1024;

  static WsScreenSize of(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= desktop) return WsScreenSize.desktop;
    if (w >= tablet) return WsScreenSize.tablet;
    return WsScreenSize.mobile;
  }

  static bool isMobile(BuildContext c) => of(c) == WsScreenSize.mobile;
  static bool isTablet(BuildContext c) => of(c) == WsScreenSize.tablet;
  static bool isDesktop(BuildContext c) => of(c) == WsScreenSize.desktop;

  /// Pick a value per size class without a switch at every call site.
  static T value<T>(
    BuildContext context, {
    required T mobile,
    T? tablet,
    T? desktop,
  }) {
    switch (of(context)) {
      case WsScreenSize.desktop:
        return desktop ?? tablet ?? mobile;
      case WsScreenSize.tablet:
        return tablet ?? mobile;
      case WsScreenSize.mobile:
        return mobile;
    }
  }

  /// Columns for a card grid. The dashboard KPI grid was hardcoded to 2, which
  /// leaves most of a desktop window empty.
  static int gridColumns(BuildContext context) =>
      value(context, mobile: 2, tablet: 3, desktop: 4);

  /// Comfortable page padding.
  static EdgeInsets pagePadding(BuildContext context) => EdgeInsets.symmetric(
    horizontal: value(context, mobile: 12.0, tablet: 24.0, desktop: 32.0),
    vertical: 12,
  );
}

/// Centres its child and caps how wide it can grow.
///
/// [maxWidth] defaults to 560 — roughly 75 characters at this type size, which
/// is the upper end of readable line length. Forms use 420.
class WsMaxWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  const WsMaxWidth({
    super.key,
    required this.child,
    this.maxWidth = 560,
    this.padding,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    ),
  );
}
