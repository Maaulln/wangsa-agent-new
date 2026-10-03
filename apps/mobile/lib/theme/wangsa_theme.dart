import 'package:flutter/material.dart';

import 'glass/wangsa_glass.dart';

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

  // Dark theme — diselaraskan dengan palet lokal ChatPage/SignupPage
  // (`_ChatDark`/`_AuthDark`) supaya seluruh aplikasi terasa satu produk:
  // hitam pekat solid, bukan abu-abu Material default. Halaman lain
  // (Settings/Profile/AgentBuilder) memakai `Theme.of(context)` biasa,
  // jadi menyamakan token di sini otomatis menyelaraskan semuanya tanpa
  // menyentuh tiap halaman satu per satu.
  static const backgroundDark = Color(0xFF000000);
  static const surfaceDark = Color(0xFF1C1C1E);
  static const surfaceMutedDark = Color(0xFF2A2A2A);
  static const foregroundDark = Color(0xFFFAFAFA);
  static const foregroundMutedDark = Color(0xFF8E8E93);
  static const borderDark = Color(0xFF2C2C2E);

  static const primaryDark = Color(0xFF0A84FF);
  static const primarySubtleDark = Color(0xFF1E1B4B);
  static const primaryMutedDark = Color(0xFFC7D2FE);

  // Galat di tema gelap: merah terang (kontras >= 6:1 di atas #000/#1C1C1E)
  // dan wadah galat kemerahan — sebelumnya wadah galat memakai indigo
  // (primarySubtleDark) sehingga banner galat tampak seperti info.
  static const dangerDark = Color(0xFFFF6B63);
  static const dangerSubtleDark = Color(0xFF3B1214);
}

/// Skala radius sudut Wangsa — satu-satunya sumber nilai lengkung.
///
/// Aturan konsentris: elemen di dalam wadah ber-padding memakai
/// `radius luar − padding` (mis. segmen di pil 24 dengan padding 4 → 20),
/// supaya kedua lengkung sejajar dan tidak tampak "gemuk" di sudut.
abstract final class WangsaRadius {
  /// Thumbnail kecil, chip dalam teks.
  static const xs = 8.0;

  /// Baris daftar, input, tombol kecil.
  static const sm = 12.0;

  /// Kartu, banner, popover, gelembung pesan.
  static const md = 16.0;

  /// Elemen dalam pil (segmen, tombol di composer).
  static const lg = 20.0;

  /// Sheet, drawer, permukaan kaca besar.
  static const xl = 24.0;

  /// Bentuk kapsul penuh.
  static const pill = 999.0;
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
      error: WangsaColors.dangerDark,
      onError: WangsaColors.backgroundDark,
      errorContainer: WangsaColors.dangerSubtleDark,
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
      extensions: <ThemeExtension<dynamic>>[
        brightness == Brightness.dark ? WangsaGlass.dark : WangsaGlass.light,
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBackground,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
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
      // Skala jarak Wangsa adalah kelipatan 4; radius mengikuti
      // [WangsaRadius] — md untuk permukaan konten, sm untuk kendali.
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outline),
          borderRadius: BorderRadius.circular(WangsaRadius.md),
        ),
      ),
      drawerTheme: DrawerThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(WangsaRadius.xl),
          ),
        ),
        endShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(WangsaRadius.xl),
          ),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(WangsaRadius.xl),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WangsaRadius.sm),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outline),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WangsaRadius.xl),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(WangsaRadius.sm),
    borderSide: BorderSide(color: color),
  );
}
