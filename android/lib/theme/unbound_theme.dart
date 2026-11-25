// Unbound Muzik — design tokens (Decision 10).
// Vortex palette, built 2026-11-24 from Daniel's vortex image: deep
// navy background #010E28, cards #0A2037, player bar / Now Playing
// #1C3C62. Bright cyan #2FB9D6 is the primary accent, ice #A9F4F9
// the bright accent, mid cyan-blue #61BADD secondary, and soft pink
// #EFAEB7 the warm accent from the vortex's pink streaks. This
// SUPERSEDES the #0F0E1C / #1B1930 / #242145 violet palette built
// 2026-11-21. APK-only — the web app keeps its own copies of the
// old tokens (#050505 / #0B0B12); the tokens are duplicated in two
// files, not shared, so changing these changes the APK only.
// Space Grotesk headlines, Inter body. Frosted glass ONLY on the
// now-playing card and the player bar — glass is expensive on the
// A16, so it stays rare. No 3D, no fake content.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class UnboundColors {
  static const voidBlack = Color(0xFF010E28);
  static const ink = Color(0xFF0A2037);
  static const playerBar = Color(0xFF1C3C62);
  static const aqua = Color(0xFF2FB9D6);
  static const aquaBright = Color(0xFFA9F4F9);
  static const sky = Color(0xFF61BADD);
  static const rose = Color(0xFFEFAEB7);
  static const text = Color(0xFFFAFAFA);
  static const textDim = Color(0x8CFFFFFF);
  static const textFaint = Color(0x66FFFFFF);
  static const glassBg = Color(0x0AFFFFFF);
  static const glassBorder = Color(0x14FFFFFF);

  static const gradient = LinearGradient(
    colors: [aqua, aquaBright],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

class UnboundTheme {
  /// System-bar icon brightness for the dark theme. Applied with an
  /// AnnotatedRegion around the Scaffold (there is no AppBar, so
  /// AppBar.systemOverlayStyle does not apply). Light icons for a dark
  /// background; bar colours are transparent because on Android 15 the
  /// bars are transparent overlays and the app's own #010E28 background
  /// is what shows through.
  static final systemUiOverlayStyle = SystemUiOverlayStyle.light.copyWith(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: UnboundColors.voidBlack,
      colorScheme: const ColorScheme.dark(
        primary: UnboundColors.aqua,
        secondary: UnboundColors.sky,
        surface: UnboundColors.ink,
        onSurface: UnboundColors.text,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        displayLarge: GoogleFonts.spaceGrotesk(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          color: UnboundColors.text,
        ),
        headlineMedium: GoogleFonts.spaceGrotesk(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          color: UnboundColors.text,
        ),
        titleLarge: GoogleFonts.spaceGrotesk(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: UnboundColors.text,
        ),
        titleMedium: GoogleFonts.spaceGrotesk(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: UnboundColors.text,
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 16,
          color: UnboundColors.text,
        ),
        bodySmall: GoogleFonts.inter(
          fontSize: 14,
          color: UnboundColors.textDim,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: UnboundColors.voidBlack,
        selectedItemColor: UnboundColors.aquaBright,
        unselectedItemColor: UnboundColors.textDim,
        type: BottomNavigationBarType.fixed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: UnboundColors.voidBlack,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    );
  }
}
