import 'package:flutter/material.dart';

/// Iron Edge theme — dark default + light alternate (Onda 8).
class IronTheme {
  // Dark palette (default)
  static const cyan = Color(0xFF00FFFF);
  static const magenta = Color(0xFFFF00FF);
  static const bgDark = Color(0xFF05060A);
  static const bgPanel = Color(0xFF0B0F1A);
  static const bgElev = Color(0xFF111726);
  static const fgDim = Color(0xFFA0AABF);
  static const fgBright = Color(0xFFE6F2FF);
  static const danger = Color(0xFFFF3366);
  static const ok = Color(0xFF39FF14);

  // Light palette (alternate)
  static const lightBg = Color(0xFFFAFAFF);
  static const lightPanel = Color(0xFFF0F0F7);
  static const lightElev = Color(0xFFFFFFFF);
  static const lightFgBright = Color(0xFF0E0E18);
  static const lightFgDim = Color(0xFF6A6A82);
  static const lightAccent = Color(0xFF0891B2);
  static const lightAccent2 = Color(0xFF5B3EE8);

  static ThemeData build({bool light = false}) {
    if (light) return _buildLight();
    return _buildDark();
  }

  static ThemeData _buildDark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bgDark,
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: magenta,
        surface: bgPanel,
        onPrimary: Colors.black,
        onSecondary: Colors.black,
        onSurface: fgBright,
        error: danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgPanel,
        foregroundColor: cyan,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: cyan,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: bgPanel),
      cardTheme: CardTheme(
        color: bgElev,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0x4400FFFF)),
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: fgBright,
        displayColor: fgBright,
      ),
      iconTheme: const IconThemeData(color: cyan),
      dividerColor: const Color(0x2200FFFF),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cyan,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgPanel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x4400FFFF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x4400FFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cyan, width: 1.4),
        ),
      ),
    );
  }

  static ThemeData _buildLight() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: lightBg,
      colorScheme: const ColorScheme.light(
        primary: lightAccent,
        secondary: lightAccent2,
        surface: lightPanel,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: lightFgBright,
        error: Color(0xFFDC2626),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: lightPanel,
        foregroundColor: lightAccent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: lightAccent,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: lightPanel),
      cardTheme: CardTheme(
        color: lightElev,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0x33000000)),
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: lightFgBright,
        displayColor: lightFgBright,
      ),
      iconTheme: const IconThemeData(color: lightAccent),
      dividerColor: const Color(0x22000000),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: lightAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightElev,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x33000000)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x33000000)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: lightAccent, width: 1.4),
        ),
      ),
    );
  }
}

class NeonGlow extends StatelessWidget {
  final Widget child;
  final Color color;
  const NeonGlow({super.key, required this.child, this.color = IronTheme.cyan});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(color: color.withOpacity(0.45), blurRadius: 18, spreadRadius: 1),
        ],
      ),
      child: child,
    );
  }
}
