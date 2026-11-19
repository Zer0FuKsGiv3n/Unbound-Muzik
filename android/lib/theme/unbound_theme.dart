// Unbound Muzik — design tokens (Decision 10).
// Same tokens as the web app: void #050505, ink #0b0b12, violet #8b5cf6,
// sky #38bdf8, mint #34d399. Space Grotesk headlines, Inter body.
// Frosted glass ONLY on the now-playing card and the player bar — glass
// is expensive on the A16, so it stays rare. No 3D, no fake content.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class UnboundColors {
  static const voidBlack = Color(0xFF050505);
  static const ink = Color(0xFF0B0B12);
  static const violet = Color(0xFF8B5CF6);
  static const violetBright = Color(0xFFA78BFA);
  static const sky = Color(0xFF38BDF8);
  static const mint = Color(0xFF34D399);
  static const text = Color(0xFFFAFAFA);
  static const textDim = Color(0x8CFFFFFF);
  static const textFaint = Color(0x66FFFFFF);
  static const glassBg = Color(0x0AFFFFFF);
  static const glassBorder = Color(0x14FFFFFF);

  static const gradient = LinearGradient(
    colors: [violet, sky],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

class UnboundTheme {
  /// System-bar icon brightness for the dark theme. Applied with an
  /// AnnotatedRegion around the Scaffold (there is no AppBar, so
  /// AppBar.systemOverlayStyle does not apply). Light icons for a dark
  /// background; bar colours are transparent because on Android 15 the
  /// bars are transparent overlays and the app's own #050505 background
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
        primary: UnboundColors.violet,
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
        selectedItemColor: UnboundColors.violetBright,
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
