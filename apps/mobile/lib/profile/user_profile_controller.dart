import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Profil pengguna lokal-di-perangkat — Wangsa belum punya sistem akun
/// (lihat `ProfilePage`), jadi ini bukan identitas yang diverifikasi.
/// Isinya hanya dua kolom bebas yang dikirim sebagai konteks ke Agent
/// lewat `WangsaApiClient.sendMessage` (`userName`/`userBio`), supaya
/// balasan AI disesuaikan tanpa perlu login: nama panggilan, dan
/// preferensi singkat (gaya bicara, bahasa, dll.).
class UserProfile {
  final String name;
  final String preferences;

  const UserProfile({this.name = '', this.preferences = ''});

  bool get isEmpty => name.trim().isEmpty && preferences.trim().isEmpty;

  UserProfile copyWith({String? name, String? preferences}) => UserProfile(
        name: name ?? this.name,
        preferences: preferences ?? this.preferences,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile && other.name == name && other.preferences == preferences;

  @override
  int get hashCode => Object.hash(name, preferences);
}

/// Menyimpan [UserProfile] di SharedPreferences — pola yang sama dengan
/// `ThemeController`/`LlmSettingsController`: dimuat sekali di `main()`,
/// satu instance dipakai sepanjang umur aplikasi.
class UserProfileController extends ValueNotifier<UserProfile> {
  static const _prefsNameKey = 'wangsa_user_profile_name';
  static const _prefsPreferencesKey = 'wangsa_user_profile_preferences';

  final SharedPreferences _prefs;

  UserProfileController._(this._prefs, super.initial);

  /// Aplikasi sungguhan selalu lewat sini.
  static Future<UserProfileController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return UserProfileController._(
      prefs,
      UserProfile(
        name: prefs.getString(_prefsNameKey) ?? '',
        preferences: prefs.getString(_prefsPreferencesKey) ?? '',
      ),
    );
  }

  @visibleForTesting
  static UserProfileController fake({UserProfile initial = const UserProfile()}) =>
      UserProfileController._(_FakePrefs(), initial);

  Future<void> save(UserProfile profile) async {
    value = profile;
    await _prefs.setString(_prefsNameKey, profile.name);
    await _prefs.setString(_prefsPreferencesKey, profile.preferences);
  }
}

/// Jalur pintas untuk [UserProfileController.fake] — widget test tidak
/// perlu channel SharedPreferences sungguhan. Sama seperti `_FakePrefs`
/// di `llm_settings_controller.dart`, disalin di sini alih-alih
/// diekspor lintas berkas supaya kedua controller tetap independen.
class _FakePrefs implements SharedPreferences {
  final Map<String, Object> _values = {};

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
