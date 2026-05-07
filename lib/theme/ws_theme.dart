import 'package:flutter/material.dart';

class WsColors {
  static const primary = Color(0xFF007ECC);
  static const primaryLight = Color(0xFF5AB4F1);
  static const primaryDark = Color(0xFF005A99);
  static const text1 = Colors.black;
  static const text2 = Colors.black87;
  static const text3 = Colors.black54;
  static const green = Color(0xFF43A047);
  static const greenLight = Color(0xFFC8E6C9);
  static const amber = Color(0xFFE65100);
  static const amberLight = Color(0xFFFFCC80);
  static const teal = Color(0xFF009688);
  static const tealLight = Color(0xFFB2DFDB);
  static const red = Color(0xFFD32F2F);
  static const redLight = Color(0xFFFFCDD2);
  static const purple = Color(0xFF673AB7);
  static const scaffoldBg = Color(0xFFF0F4F8);
}

class WsTheme {
  static ThemeData light() {
    return ThemeData(
      primaryColor: WsColors.primary,
      scaffoldBackgroundColor: WsColors.scaffoldBg,
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: WsColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: WsColors.primary,
        unselectedItemColor: WsColors.text3,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        unselectedLabelStyle: TextStyle(fontSize: 12),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1.5,
        shadowColor: Colors.black12,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

class WsKpiCard extends StatelessWidget {
  final String icon;
  final String value;
  final String label;
  final String? trend;
  final Color accentColor;
  final VoidCallback? onTap;

  const WsKpiCard({super.key, required this.icon, required this.value, required this.label, this.trend, required this.accentColor, this.onTap});

  @override Widget build(BuildContext context) {
    Widget card = Card(
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: accentColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(icon, style: const TextStyle(fontSize: 22)),
                    const SizedBox(height: 6),
                    Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: accentColor)),
                    Text(label, style: const TextStyle(fontSize: 10, color: WsColors.text3), maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (trend != null) ...[
                      const Spacer(),
                      Text(trend!, style: TextStyle(fontSize: 11, color: accentColor, fontWeight: FontWeight.w600)),
                    ]
                  ],
                ),
              ),
            ),
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
