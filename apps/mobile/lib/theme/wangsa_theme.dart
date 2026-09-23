import 'package:flutter/material.dart';

/// Token warna Wangsa, disalin apa adanya dari `DESIGN.md`.
///
/// Nilainya ditulis eksplisit, bukan diturunkan lewat `ColorScheme.fromSeed`,
/// karena fromSeed akan menggeser warna hasil ke rentang buatannya sendiri
/// dan indigo yang jadi identitas Wangsa tidak lagi persis. Kalau
/// `DESIGN.md` berubah, berkas ini yang ikut berubah, satu tempat saja.
abstract final class WangsaColors {
  // Light theme
  static const background = Color(0xFFFAFAFA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF4F4F5);
  static const foreground = Color(0xFF18181B);
  static const foregroundMuted = Color(0xFF71717A);
  static const border = Color(0xFFE4E4E7);

  static const primary = Color(0xFF4F46E5);
  static const primarySubtle = Color(0xFFEEF2FF);
  static const primaryActive = Color(0xFF3730A3);

  static const danger = Color(0xFFDC2626);
  static const dangerSubtle = Color(0xFFFEF2F2);

  // Dark theme
  static const backgroundDark = Color(0xFF09090B);
  static const surfaceDark = Color(0xFF18181B);
  static const surfaceMutedDark = Color(0xFF27272A);
  static const foregroundDark = Color(0xFFFAFAFA);
  static const foregroundMutedDark = Color(0xFFA1A1AA);
  static const borderDark = Color(0xFF27272A);

  static const primaryDark = Color(0xFF818CF8);
  static const primarySubtleDark = Color(0xFF1E1B4B);
  static const primaryMutedDark = Color(0xFFC7D2FE);
}

/// Arah visual Wangsa adalah "soft minimalism with technical precision":
/// bersih, tenang, netral. `DESIGN.md` melarang bayangan berlebih dan
/// gradien tanpa alasan, jadi AppBar di sini rata tanpa elevasi, dan
/// permukaan dibedakan lewat garis tipis, bukan lewat bayangan.
abstract final class WangsaTheme {
  /// Dibangun sekali dan disimpan (`static final`, bukan `get`), lalu
  /// hanya dijangkau dari luar berkas ini lewat [forBrightness] — bukan
  /// dipanggil langsung sebagai `WangsaTheme.light`/`WangsaTheme.dark`.
  static final ThemeData _light = _build(
    brightness: Brightness.light,
    scheme: const ColorScheme.light(
      primary: WangsaColors.primary,
      onPrimary: Colors.white,
      primaryContainer: WangsaColors.primarySubtle,
      onPrimaryContainer: WangsaColors.primaryActive,
      secondary: WangsaColors.foregroundMuted,
      onSecondary: Colors.white,
      surface: WangsaColors.surface,
      onSurface: WangsaColors.foreground,
      surfaceContainerHighest: WangsaColors.surfaceMuted,
      onSurfaceVariant: WangsaColors.foregroundMuted,
      outline: WangsaColors.border,
      error: WangsaColors.danger,
      onError: Colors.white,
      errorContainer: WangsaColors.dangerSubtle,
      onErrorContainer: WangsaColors.danger,
    ),
    scaffoldBackground: WangsaColors.background,
  );

  static final ThemeData _dark = _build(
    brightness: Brightness.dark,
    scheme: const ColorScheme.dark(
      primary: WangsaColors.primaryDark,
      onPrimary: WangsaColors.backgroundDark,
      primaryContainer: WangsaColors.primarySubtleDark,
      onPrimaryContainer: WangsaColors.primaryMutedDark,
      secondary: WangsaColors.foregroundMutedDark,
      onSecondary: WangsaColors.backgroundDark,
      surface: WangsaColors.surfaceDark,
      onSurface: WangsaColors.foregroundDark,
      surfaceContainerHighest: WangsaColors.surfaceMutedDark,
      onSurfaceVariant: WangsaColors.foregroundMutedDark,
      outline: WangsaColors.borderDark,
      error: WangsaColors.danger,
      onError: Colors.white,
      errorContainer: WangsaColors.primarySubtleDark,
      onErrorContainer: WangsaColors.dangerSubtle,
    ),
    scaffoldBackground: WangsaColors.backgroundDark,
  );

  /// Satu-satunya jalan masuk publik ke [_light]/[_dark] — `main.dart`
  /// memanggil ini dua kali (`Brightness.light` untuk `theme`,
  /// `Brightness.dark` untuk `darkTheme`) alih-alih menjangkau field
  /// privat itu langsung, yang memang tidak bisa dari luar berkas ini.
  static ThemeData forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
    required Color scaffoldBackground,
  }) {
    return ThemeData(
      useMaterial3: true,
      // Roboto dibundel di assets/fonts (lihat pubspec.yaml) alih-alih
      // mengandalkan font bawaan Material per platform — tanpa ini, teks
      // tampil Roboto di Android tapi Segoe UI di Windows desktop.
      fontFamily: 'Roboto',
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBackground,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(color: scheme.outline, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: _inputBorder(scheme.outline),
        enabledBorder: _inputBorder(scheme.outline),
        focusedBorder: _inputBorder(scheme.primary),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.onSurface,
        contentTextStyle: TextStyle(color: scheme.surface),
        behavior: SnackBarBehavior.floating,
      ),
      // Skala jarak Wangsa adalah kelipatan 4. Radius 12 dipakai untuk
      // permukaan yang membungkus konten, 8 untuk kendali kecil.
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outline),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color),
      );
}
