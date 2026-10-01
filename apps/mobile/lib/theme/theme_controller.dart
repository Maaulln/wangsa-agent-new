import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pilihan tampilan pengguna: ikut sistem, atau dipaksa terang/gelap.
///
/// Sebelum ini `MaterialApp` hanya punya `theme`/`darkTheme` tanpa kontrol
/// manual, jadi tampilan aplikasi selalu mengikuti pengaturan sistem HP
/// tanpa cara mengubahnya dari dalam aplikasi. Itu jadi masalah nyata:
/// identitas visual Wangsa di web memakai palet terang, dan pengguna
/// dengan HP bermode gelap sistem-lebar melihat aplikasi ini otomatis
/// gelap tanpa diminta, terasa tidak senada. `ThemeController` menyimpan
/// pilihan eksplisit lewat `shared_preferences` (paket open source resmi
/// tim Flutter, bukan SDK berbayar — lihat catatan lisensi di
/// docs/wake-word-setup-mobile.md soal kenapa itu jadi pertimbangan),
/// supaya pilihannya bertahan lewat mulai ulang aplikasi.
class ThemeController extends ValueNotifier<ThemeMode> {
  static const _prefsKey = 'wangsa_theme_mode';

  ThemeController._(super.initial);

  /// Jalur pintas untuk widget test yang tidak butuh `SharedPreferences`
  /// sungguhan — lihat `test/chat/chat_page_test.dart`. Aplikasi
  /// sungguhan selalu lewat [load].
  @visibleForTesting
  ThemeController.withMode(super.mode);

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    return ThemeController._(_decode(stored));
  }

  Future<void> setMode(ThemeMode mode) async {
    if (value == mode) return;
    value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, _encode(mode));
  }

  static ThemeMode _decode(String? stored) => switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        // Bawaan gelap (bukan `system`): identitas visual Wangsa di
        // ChatPage/SignupPage selalu hitam pekat solid, jadi aplikasi
        // dibuka gelap dari awal supaya terasa satu produk yang sama,
        // alih-alih terang di sebagian halaman kalau sistem HP-nya
        // terang. Pengguna tetap bisa memilih terang manual di
        // Pengaturan — ini hanya bawaan sebelum ada pilihan tersimpan.
        _ => ThemeMode.dark,
      };

  static String _encode(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
}
