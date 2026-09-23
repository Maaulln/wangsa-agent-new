import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm_override.dart';

/// Brankas kunci — satu-satunya berkas yang boleh mengimpor
/// `flutter_secure_storage` (isolasi kanal platform yang sama seperti
/// `foreground_service.dart`): test memakai [_FakeKeyVault], bukan kanal
/// sungguhan.
abstract interface class KeyVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureKeyVault implements KeyVault {
  final FlutterSecureStorage _storage;

  SecureKeyVault({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Pilihan model AI pengguna, bertahan lewat mulai ulang aplikasi.
///
/// * `null` = bawaan deployment (default Gemma). Tidak ada kunci yang
///   disimpan di mana pun dalam keadaan ini.
/// * Non-null = kunci + endpoint + model milik pengguna (BYOK).
///   **Kunci API disimpan di Keystore (Android) / Keychain (iOS) via
///   [SecureKeyVault], tidak pernah di SharedPreferences** — prefs hanya
///   menyimpan baseURL, nama model, dan fakta bahwa mode custom aktif
///   (semuanya bukan rahasia). Kunci hanya keluar dari brankas saat
///   dikirim sebagai badan HTTPS ke API Wangsa sendiri, yang
///   meneruskannya ke provider LLM untuk permintaan itu saja (tidak
///   disimpan di server — lihat `PublicSendAgentMessageInputSchema` di
///   apps/api). Jangan isi kunci production yang tidak boleh transit
///   lewat server ini.
class LlmSettingsController extends ValueNotifier<LlmOverride?> {
  static const _prefsEnabledKey = 'wangsa_llm_custom_enabled';
  static const _prefsBaseUrlKey = 'wangsa_llm_base_url';
  static const _prefsModelKey = 'wangsa_llm_model';
  static const _vaultApiKey = 'wangsa_llm_api_key';

  /// Preset endpoint OpenAI-compatible yang umum dipakai.
  static const Map<String, String> presets = {
    'OpenAI': 'https://api.openai.com/v1',
    'OpenRouter': 'https://openrouter.ai/api/v1',
    'Kustom': '',
  };

  final SharedPreferences _prefs;
  final KeyVault _vault;

  LlmSettingsController._(this._prefs, this._vault, super.initial);

  /// Aplikasi sungguhan selalu lewat sini. Widget test yang tidak butuh
  /// penyimpanan sungguhan bisa memakai [LlmSettingsController.fake].
  static Future<LlmSettingsController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return LlmSettingsController._(prefs, SecureKeyVault(), await _readCurrent(prefs, SecureKeyVault()));
  }

  @visibleForTesting
  static LlmSettingsController fake({LlmOverride? initial, KeyVault? vault, Map<String, Object>? prefsValues}) {
    final prefs = _FakePrefs(values: prefsValues ?? {});
    return LlmSettingsController._(prefs, vault ?? _FakeKeyVault(), initial);
  }

  static Future<LlmOverride?> _readCurrent(SharedPreferences prefs, KeyVault vault) async {
    if (prefs.getBool(_prefsEnabledKey) != true) return null;
    final baseURL = (prefs.getString(_prefsBaseUrlKey) ?? '').trim();
    final model = (prefs.getString(_prefsModelKey) ?? '').trim();
    final apiKey = (await vault.read(_vaultApiKey) ?? '').trim();
    if (baseURL.isEmpty || model.isEmpty || apiKey.isEmpty) return null;
    return LlmOverride(baseURL: baseURL, apiKey: apiKey, model: model);
  }

  /// Mengaktifkan mode custom dan menyimpan ketiganya. Mengembalikan null
  /// bila berhasil, atau pesan galat yang aman ditampilkan bila ada kolom
  /// yang kosong.
  Future<String?> saveCustom({
    required String baseURL,
    required String apiKey,
    required String model,
  }) async {
    if (baseURL.trim().isEmpty || apiKey.trim().isEmpty || model.trim().isEmpty) {
      return 'Base URL, API key, dan nama model wajib diisi.';
    }
    final uri = Uri.tryParse(baseURL.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return 'Base URL harus http(s), mis. https://api.openai.com/v1.';
    }
    final override = LlmOverride(baseURL: baseURL.trim(), apiKey: apiKey.trim(), model: model.trim());
    await _vault.write(_vaultApiKey, override.apiKey);
    await _prefs.setBool(_prefsEnabledKey, true);
    await _prefs.setString(_prefsBaseUrlKey, override.baseURL);
    await _prefs.setString(_prefsModelKey, override.model);
    value = override;
    return null;
  }

  /// Kembali ke bawaan deployment (default Gemma) dan menghapus kunci
  /// dari brankas.
  Future<void> useDefault() async {
    await _vault.delete(_vaultApiKey);
    await _prefs.setBool(_prefsEnabledKey, false);
    value = null;
  }

  bool get isCustom => value != null;
}

/// SharedPreferences dalam-memori untuk test — hanya mengimplementasikan
/// anggota yang dipakai controller ini.
class _FakePrefs implements SharedPreferences {
  final Map<String, Object> _values;
  _FakePrefs({required Map<String, Object> values}) : _values = Map.of(values);

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<bool> setBool(String key, bool value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeKeyVault implements KeyVault {
  final Map<String, String> store = {};
  @override
  Future<String?> read(String key) async => store[key];
  @override
  Future<void> write(String key, String value) async => store[key] = value;
  @override
  Future<void> delete(String key) async => store.remove(key);
}
