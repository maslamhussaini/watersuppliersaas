// =============================================================================
// lib/theme/ws_theme.dart
// Palette and theme, adopted from OrderMate.
//
// The colour values, radii, elevations and the AppBar gradient come from
// OrderMate's app_colors.dart / app_theme.dart. The NAMES are unchanged —
// WsColors.primary, .text3, .amber and so on — because ~40 files reference
// them. Renaming to OrderMate's scheme (AppColors.textSecondary etc.) would
// have been a rename of every screen for no visual difference.
//
// NOT copied: GoogleFonts.poppinsTextTheme. google_fonts downloads the family
// at first run, so a desktop build with no network silently falls back and a
// CI build gets slower. If you want Poppins, add `google_fonts: ^6.1.0` to
// pubspec.yaml and swap the `fontFamily` line for
// `textTheme: GoogleFonts.poppinsTextTheme()` — everything else already
// matches.
// =============================================================================

import 'package:flutter/material.dart';

class WsColors {
  // ── OrderMate core palette ────────────────────────────────────────────────
  static const primary = Color(0xFF054C78);      // deep blue
  static const primaryDark = Color(0xFF00365B);
  static const primaryLight = Color(0xFF00AEEF); // bright cyan

  /// Very light primary wash, for avatar and chip backgrounds. OrderMate used
  /// Colors.blue.shade50 inline for this; naming it keeps the tint in one
  /// place.
  static const primarySurface = Color(0xFFE1F1FA);

  static const accent = Color(0xFF00BCD4);

  // ── Text ──────────────────────────────────────────────────────────────────
  static const text1 = Color(0xFF212121);
  static const text2 = Color(0xFF757575);
  static const text3 = Color(0xFF9E9E9E);
  static const textHint = Color(0xFFBDBDBD);

  // ── Status ────────────────────────────────────────────────────────────────
  static const green = Color(0xFF4CAF50);
  static const greenLight = Color(0xFFC8E6C9);
  static const amber = Color(0xFFFFA726);
  static const amberLight = Color(0xFFFFE0B2);
  static const teal = Color(0xFF009688);
  static const tealLight = Color(0xFFB2DFDB);
  static const red = Color(0xFFF44336);
  static const redLight = Color(0xFFFFCDD2);
  static const purple = Color(0xFF9C27B0);
  static const indigo = Color(0xFF3F51B5);
  static const orange = Color(0xFFFF9800);

  // ── Surfaces ──────────────────────────────────────────────────────────────
  static const scaffoldBg = Color(0xFFF5F5F5);
  static const border = Color(0xFFE0E0E0);

  /// The AppBar / login gradient. Vertical, deep blue to cyan.
  static const headerGradient = LinearGradient(
    colors: [Color(0xFF054C78), Color(0xFF00AEEF)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

class WsTheme {
  static ThemeData light() {
    return ThemeData(
      primaryColor: WsColors.primary,
      scaffoldBackgroundColor: WsColors.scaffoldBg,
      fontFamily: 'Roboto',
      // OrderMate centres its titles and uses white-on-primary with no
      // elevation. The gradient is applied per-AppBar via WsGradientBar,
      // because AppBarTheme cannot carry a flexibleSpace.
      appBarTheme: const AppBarTheme(
        backgroundColor: WsColors.primary,
        foregroundColor: Colors.white,
        iconTheme: IconThemeData(color: Colors.white),
        actionsIconTheme: IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: WsColors.primary,
        unselectedItemColor: WsColors.text3,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        unselectedLabelStyle: TextStyle(fontSize: 12),
      ),
      // OrderMate: elevation 2, radius 12.
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shadowColor: Colors.black26,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.black12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.black12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: WsColors.primary, width: 2),
        ),
        labelStyle: const TextStyle(color: WsColors.text2),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: WsColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: WsColors.text1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          side: const BorderSide(color: Colors.black26),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

class WsSectionHeader extends StatelessWidget {
  final String title;
  const WsSectionHeader(this.title, {super.key});
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
    child: Text(title.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: WsColors.text3, letterSpacing: 0.5))
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// OrderMate UI kit
//
// The five patterns lifted from OrderMate: the gradient app bar, the gradient
// stat card, the pill search field, the empty state, and the form section
// heading. Ported as widgets rather than copied inline so the look is set in
// one place — OrderMate repeated its search field's decoration in every list
// screen, which is why they had drifted apart from each other.
// ═══════════════════════════════════════════════════════════════════════════

/// Drop into `AppBar.flexibleSpace` for OrderMate's deep-blue-to-cyan header.
///
///     AppBar(title: const Text('Products'), flexibleSpace: const WsGradientBar())
class WsGradientBar extends StatelessWidget {
  const WsGradientBar({super.key});
  @override
  Widget build(BuildContext context) =>
      const DecoratedBox(decoration: BoxDecoration(gradient: WsColors.headerGradient));
}

/// OrderMate's dashboard tile: a tinted gradient panel, the icon in a rounded
/// swatch, the caption, then the number large and in the accent colour.
///
/// Unlike the older WsKpiCard this one leads with the icon block and puts the
/// value last, which is OrderMate's order.
class WsStatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String? footnote;
  final VoidCallback? onTap;

  const WsStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.footnote,
    this.onTap,
  });

  /// Height the FULL card needs at text scale 1.0.
  ///
  /// Exported so the grids can size their rows from it instead of guessing.
  /// The overflow this replaces came from exactly that guess: the grid was
  /// left at 140 from the previous, smaller card while the card grew an icon
  /// block, a bigger number and a footnote. Two numbers that must agree, kept
  /// in two files, disagreed. Now there is one.
  static const double preferredHeight = 186;

  /// Below this the card drops to its compact form rather than overflowing.
  static const double _compactBelow = 150;

  @override
  Widget build(BuildContext context) {
    Widget card = Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        // A card that cannot know its height cannot be laid out safely by
        // arithmetic alone, so it measures. Given a short box it sheds the
        // footnote and the second title line instead of painting stripes.
        child: LayoutBuilder(
          builder: (context, c) {
            final compact = c.maxHeight.isFinite && c.maxHeight < _compactBelow;
            return Container(
              padding: EdgeInsets.all(compact ? 12 : 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  colors: [
                    color.withValues(alpha: 0.10),
                    color.withValues(alpha: 0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                // min, so the card also survives an unbounded-height parent
                // such as the plain Row on the Payments screen.
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(compact ? 7 : 10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.20),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: compact ? 18 : 26),
                  ),
                  SizedBox(height: compact ? 8 : 12),
                  Text(
                    title,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      height: 1.25,
                      fontWeight: FontWeight.w500,
                      color: WsColors.text2,
                    ),
                  ),
                  SizedBox(height: compact ? 2 : 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: compact ? 21 : 26,
                        height: 1.1,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ),
                  if (footnote != null && !compact) ...[
                    const SizedBox(height: 2),
                    Text(
                      footnote!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600, color: color),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
    return card;
  }
}

/// OrderMate's search field: filled grey pill, no outline, magnifier prefix.
/// Adds a clear button, which OrderMate left out — with no border there is no
/// other affordance for emptying it.
class WsSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final EdgeInsetsGeometry padding;

  const WsSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search…',
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 8),
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: WsColors.primary, width: 1.5),
        ),
        filled: true,
        fillColor: const Color(0xFFEEEEEE),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
  );
}

/// Big muted icon, a line of explanation, an optional hint. OrderMate showed
/// a different message for "nothing exists" and "nothing matched your search",
/// which is worth keeping — they call for different actions.
class WsEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? hint;
  final Widget? action;

  const WsEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: WsColors.textHint),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, color: WsColors.text2),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: WsColors.text3),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

/// The heading OrderMate puts above each block of form fields
/// ("Basic Information", "Classification", "Pricing").
class WsFormSection extends StatelessWidget {
  final String title;
  final bool first;
  const WsFormSection(this.title, {super.key, this.first = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: first ? 0 : 24, bottom: 12),
    child: Text(
      title,
      style: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, color: WsColors.text1),
    ),
  );
}

class WsKpiCard extends StatelessWidget {
  final String icon;
  final String value;
  final String label;
  final String? trend;
  final Color accentColor;
  final VoidCallback? onTap;

  const WsKpiCard({super.key, required this.icon, required this.value, required this.label, this.trend, required this.accentColor, this.onTap});

  // WHY THIS LAYOUT IS THE WAY IT IS
  //
  // The old one overflowed by 13 px in a narrow window. Its content height was
  // fixed (22 px icon + 22 px value + two label lines + trend + 24 px padding)
  // while the grid gave it a height derived from its WIDTH via
  // childAspectRatio. Narrow the window and the height shrinks while the
  // content does not — so the break was guaranteed at some width, and the only
  // question was which one.
  //
  // Three changes make it unbreakable rather than merely tuned:
  //   · no Spacer — it demands leftover space that may not exist;
  //   · the label is Flexible and ellipsises, so it yields first;
  //   · the value is a FittedBox, so "Rs 1,250,000" shrinks instead of clipping.
  // The grid now also fixes the card HEIGHT (mainAxisExtent) instead of
  // deriving it from the width. See dashboard_screen.dart.
  //
  // THE CARD MUST NOT CARE HOW TALL ITS PARENT IS.
  //
  // It is used in two different kinds of parent: a GridView, which hands it a
  // fixed height, and a plain Row on the Payments screen, which hands it an
  // UNBOUNDED height. The previous version drew the accent stripe with
  //   Row(crossAxisAlignment: stretch, children: [Container(width: 4), ...])
  // which asks the stripe to be as tall as the row — meaningless when the row
  // has no height, so it resolved to infinity and the Card's RenderPhysicalShape
  // could not be laid out at all. That is the blank Payments screen and the
  // "RenderBox was not laid out" flood. IntrinsicHeight had been hiding it by
  // measuring the content first; removing it exposed the real dependency.
  //
  // A left BORDER needs no such negotiation: it is painted by the decoration,
  // whatever height the box ends up. Nothing here reads its parent's height,
  // so the card shrink-wraps when unbounded and fills when bounded.
  //
  // Note there is no Flexible either. Flexible in a Column with an unbounded
  // main axis is itself an error ("non-zero flex but incoming height
  // constraints are unbounded"), so it would have swapped one crash for
  // another. maxLines caps the label's height without needing the parent.
  @override Widget build(BuildContext context) {
    Widget card = Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: accentColor, width: 4)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: const TextStyle(fontSize: 20, height: 1.1)),
            const SizedBox(height: 4),
            // Long money values shrink to fit rather than overflow.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                    fontSize: 22,
                    height: 1.1,
                    fontWeight: FontWeight.bold,
                    color: accentColor),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                  fontSize: 10, height: 1.25, color: WsColors.text3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (trend != null) ...[
              const SizedBox(height: 4),
              Text(
                trend!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    color: accentColor,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
    return onTap != null ? InkWell(onTap: onTap, child: card) : card;
  }
}

class WsBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;

  const WsBadge({super.key, required this.label, required this.bg, required this.fg});

  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
    child: Text(label, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w600)),
  );
}

class WsHealthBar extends StatelessWidget {
  final double value;
  final Color? color;
  final double? height;
  const WsHealthBar({super.key, required this.value, this.color, this.height});
  
  @override
  Widget build(BuildContext context) {
    return LinearProgressIndicator(value: value, color: color, minHeight: height);
  }
}

Future<bool> wsShowDeleteDialog(BuildContext context, {required String title, required String content}) async {
  return await showDialog<bool>(context: context, builder: (c) => AlertDialog(
    title: Text(title),
    content: Text(content),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
    ]
  )) ?? false;
}
