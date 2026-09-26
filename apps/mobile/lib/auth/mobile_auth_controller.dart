import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sesi auth mobile: token + profile milik user ini.
///
/// Disimpan di SharedPreferences (cukup untuk Fase 1; pindah ke
/// secure storage bila token dianggap sensitif tinggi). Api URL tetap
/// di kunci terpisah `wangsa_chat_api_url` agar tidak tertukar dengan
/// API pekerjaan produk.
class MobileAuthController extends ChangeNotifier {
  static const String tokenKey = 'wangsa_mobile_token';
  static const String profileKey = 'wangsa_mobile_profile';

  String? _token;
  String? _profile;

  MobileAuthController({String? token, String? profile})
    : _token = token,
      _profile = profile;

  static Future<MobileAuthController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return MobileAuthController(
      token: prefs.getString(tokenKey),
      profile: prefs.getString(profileKey),
    );
  }

  String? get token => _token;
  String? get profile => _profile;
  bool get isSignedIn => _token != null && _token!.isNotEmpty;

  Future<void> saveSession({
    required String token,
    required String profile,
  }) async {
    _token = token;
    _profile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tokenKey, token);
    await prefs.setString(profileKey, profile);
    notifyListeners();
  }

  Future<void> clear() async {
    _token = null;
    _profile = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokenKey);
    await prefs.remove(profileKey);
    notifyListeners();
  }
}
