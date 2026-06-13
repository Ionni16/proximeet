// lib/core/theme.dart
//
// Tema dell'applicazione, estratto da main.dart per separare la
// configurazione visuale dalla logica di bootstrap.
// ─────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Tema centralizzato di ProxiMeet.
///
/// `dark()` è il tema principale dell'app; `light()` esiste come
/// fallback ma l'app forza `ThemeMode.dark`.
abstract final class AppTheme {
  // ── Palette ────────────────────────────────────────────────
  static const Color primary = Color(0xFF4D8EF7);
  static const Color primaryDark = Color(0xFF1A56DB);
  static const Color bgDeep = Color(0xFF050D1E);
  static const Color bgCard = Color(0xFF0D1B30);
  static const Color bgSurface = Color(0xFF101E35);
  static const Color textPrimary = Color(0xFFE8F0FE);
  static const Color textSecondary = Color(0xFF8BA3C7);
  static const Color borderColor = Color(0xFF1A2D47);
  static const Color errorColor = Color(0xFFEF5350);

  // ── Dark theme (principale) ────────────────────────────────
  static ThemeData dark() {
    const cs = ColorScheme(
      brightness: Brightness.dark,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFF1A3560),
      onPrimaryContainer: Color(0xFF90CAF9),
      secondary: Color(0xFF64B5F6),
      onSecondary: bgDeep,
      secondaryContainer: Color(0xFF1A3560),
      onSecondaryContainer: Color(0xFF90CAF9),
      tertiary: Color(0xFF80DEEA),
      onTertiary: bgDeep,
      tertiaryContainer: Color(0xFF003B4A),
      onTertiaryContainer: Color(0xFF80DEEA),
      error: errorColor,
      onError: Colors.white,
      errorContainer: Color(0xFF4A1010),
      onErrorContainer: Color(0xFFEF9A9A),
      surface: bgCard,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: Color(0xFF2A3F5F),
      outlineVariant: borderColor,
      shadow: Colors.black,
      scrim: Colors.black87,
      inverseSurface: textPrimary,
      onInverseSurface: bgDeep,
      inversePrimary: primaryDark,
      surfaceContainerHighest: bgSurface,
      surfaceContainerHigh: bgCard,
      surfaceContainer: bgDeep,
      surfaceContainerLow: bgDeep,
      surfaceContainerLowest: bgDeep,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: bgDeep,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
      ),
      cardTheme: CardThemeData(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: borderColor, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(primary),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3),
          ),
          elevation: const WidgetStatePropertyAll(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(primary),
          side: WidgetStatePropertyAll(
            BorderSide(color: primary.withValues(alpha: 0.4)),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(primary),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSurface,
        hintStyle: const TextStyle(color: textSecondary),
        labelStyle: const TextStyle(color: textSecondary),
        prefixIconColor: textSecondary,
        suffixIconColor: textSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: errorColor),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: errorColor, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: primary.withValues(alpha: 0.15),
        iconTheme: const WidgetStatePropertyAll(
          IconThemeData(color: textSecondary, size: 24),
        ),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: borderColor,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: borderColor,
        contentTextStyle: TextStyle(color: textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: borderColor),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: textPrimary),
        headlineMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
            color: textPrimary),
        headlineSmall: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: textPrimary),
        titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
            color: textPrimary),
        titleMedium: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, color: textPrimary),
        titleSmall: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
            color: textPrimary),
        bodyLarge: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            color: textPrimary,
            height: 1.5),
        bodyMedium: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: textPrimary,
            height: 1.5),
        bodySmall: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.1,
            color: textSecondary,
            height: 1.4),
        labelLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: textPrimary),
        labelMedium: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
            color: textSecondary),
        labelSmall: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
            color: textSecondary),
      ),
    );
  }

  // ── Light theme (fallback) ─────────────────────────────────
  static ThemeData light() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryDark,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );
  }
}
