import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_endpoints.dart';
import '../../api/wangsa_api_client.dart';
import '../../chat/bloc/chat_bloc.dart';
import '../../chat/view/chat_page.dart';
import '../../config/app_config.dart';
import '../../llm/llm_settings_controller.dart';
import '../../profile/user_profile_controller.dart';
import '../../theme/theme_controller.dart';
import '../../voice/voice_input.dart';
import '../mobile_auth_controller.dart';
import 'signup_page.dart';

/// Gerbang auth: belum daftar → [SignupPage], sudah → chat.
///
/// Stateful dengan sengaja, karena tiga hal harus stabil sepanjang sesi:
///
/// 1. [WangsaApiClient] dibuat SEKALI (bukan tiap rebuild) — tiap instance
///    memegang `http.Client` yang harus di-close; membuatnya di `build`
///    membocorkan socket setiap `notifyListeners`.
/// 2. [ChatBloc] dibuat sekali per sesi login (kunci: token + apiUrl).
///    Membuatnya di `build` berarti setiap `notifyListeners` me-reset
///    riwayat chat + mengulang `ChatOpened`.
/// 3. Alamat server dinamis: user boleh mengganti URL saat daftar/masuk;
///    URL itu dipakai membangun klien chat (bukan URL bawaan config yang
///    dibaca sekali saat startup).
class AuthGate extends StatefulWidget {
  final AppConfig config;
  final String? configProblem;
  final VoiceInput voiceInput;
  final ThemeController themeController;
  final LlmSettingsController llmSettings;
  final UserProfileController userProfile;
  final MobileAuthController auth;
  final WangsaApiClient? voiceApiClient;

  /// Hook pengujian: klien HTTP bersama untuk semua WangsaApiClient yang
  /// dibuat gate ini, supaya test widget bisa memakai MockClient.
  /// Produksi selalu null (klien HTTP asli).
  final http.Client? httpClient;

  const AuthGate({
    super.key,
    required this.config,
    this.configProblem,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
    required this.userProfile,
    required this.auth,
    this.voiceApiClient,
    this.httpClient,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  WangsaApiClient? _client;
  ChatBloc? _bloc;
  WangsaApiClient? _signupClient;
  String? _sessionKey;
  String _apiUrl = '';

  @override
  void initState() {
    super.initState();
    _apiUrl = widget.config.apiBaseUrl;
  }

  /// Klien HTTP milik gate ini (bukan injeksi test) yang wajib di-close.
  /// Klien injeksi milik test — jangan ditutup agar bisa dipakai ulang.
  bool get _ownsClients => widget.httpClient == null;

  @override
  void dispose() {
    _bloc?.close();
    if (_ownsClients) {
      _client?.close();
      _signupClient?.close();
    }
    super.dispose();
  }

  /// Kunci sesi login: token + apiUrl. Berubah → sesi lama dibuang.
  String? _keyFor(String? token, String apiUrl) =>
      (token == null || token.isEmpty) ? null : '$apiUrl|$token';

  /// Menyerap URL baru (dari probing fallback ChatBloc atau dialog
  /// Pengaturan) menjadi satu-satunya kebenaran: disimpan ke
  /// SharedPreferences agar `flutter run` berikutnya langsung memakai yang
  /// hidup, dan kunci sesi diselaraskan TANPA membuang ChatBloc yang sedang
  /// berjalan (kliennya sudah diperbarui di tempat oleh pemanggil).
  Future<void> _adoptApiUrl(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wangsa_chat_api_url', clean);
    } catch (_) {
      // Penyimpanan gagal — sesi jalan tetap diperbarui di bawah.
    }
    if (!mounted) return;
    setState(() {
      _apiUrl = clean;
      widget.voiceApiClient?.updateBaseUrl(clean);
      if (_sessionKey != null) {
        final token = _sessionKey!.split('|').sublist(1).join('|');
        _sessionKey = '$clean|$token';
      }
    });
  }

  void _ensureSession(String key) {
    widget.voiceApiClient
      ?..updateBaseUrl(_apiUrl)
      ..updateToken(widget.auth.token);
    if (_sessionKey == key && _client != null && _bloc != null) return;
    // Sesi berubah (login/logout/ganti server): buang yang lama.
    _bloc?.close();
    if (_ownsClients) _client?.close();
    final parts = key.split('|');
    final url = parts.first;
    final token = parts.sublist(1).join('|');
    final client = WangsaApiClient(baseUrl: url, httpClient: widget.httpClient)
      ..updateToken(token);
    _client = client;
    _bloc = ChatBloc(
      apiClient: client,
      agentId: widget.config.defaultAgentId,
      userProfile: widget.userProfile,
      candidateUrls: buildApiCandidates(
        savedUrl: url,
        envUrl: const String.fromEnvironment('WANGSA_API_BASE_URL'),
      ),
      clientFactory: (probeUrl) => WangsaApiClient(
        baseUrl: probeUrl,
        httpClient: widget.httpClient,
        requestTimeout: const Duration(seconds: 3),
      ),
      onApiBaseUrlResolved: (resolved) => _adoptApiUrl(resolved),
      // Upaya terakhir saat kandidat statis mati: telusuri subnet Wi-Fi
      // lokal HP (lib/api/api_endpoints.dart). Klien verifikasi memakai
      // httpClient gate yang sama — test widget tetap terisolasi dari
      // jaringan sungguhan selama tidak ada jalur yang benar-benar mati.
      lanDiscoverer: () => discoverLanBackendUrls(
        agentId: widget.config.defaultAgentId,
        clientFactory: widget.httpClient != null
            ? (probeUrl) => WangsaApiClient(
                baseUrl: probeUrl,
                httpClient: widget.httpClient,
                requestTimeout: const Duration(seconds: 3),
              )
            : null,
      ),
    )..add(const ChatOpened());
    _sessionKey = key;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        final token = widget.auth.token;
        final key = _keyFor(token, _apiUrl);
        if (key == null) {
          // Tidak ada sesi: pastikan sisa sesi lama dibersihkan.
          if (_sessionKey != null) {
            _bloc?.close();
            _client?.close();
            _bloc = null;
            _client = null;
            _sessionKey = null;
          }
          _signupClient ??= WangsaApiClient(
            baseUrl: _apiUrl,
            httpClient: widget.httpClient,
          );
          _signupClient!.updateBaseUrl(_apiUrl);
          return SignupPage(
            apiClient: _signupClient!,
            auth: widget.auth,
            initialApiUrl: _apiUrl,
            // URL simpanan bisa basi (mis. IP Wi-Fi lama yang sudah tidak
            // terjangkau lewat USB) — kandidat yang sama dipakai ChatBloc
            // pasca-login supaya SignupPage bisa self-heal sebelum
            // menyerah dengan galat generik. Lihat api_endpoints.dart.
            apiCandidates: buildApiCandidates(
              savedUrl: _apiUrl,
              envUrl: const String.fromEnvironment('WANGSA_API_BASE_URL'),
            ),
            onSignedIn:
                ({
                  required String token,
                  required String profile,
                  required String apiUrl,
                }) async {
                  if (!mounted) return;
                  setState(() => _apiUrl = apiUrl);
                },
          );
        }
        widget.voiceApiClient
          ?..updateBaseUrl(_apiUrl)
          ..updateToken(null);
        // Sesi chat aktif: klien signup sudah tidak dipakai.
        if (_ownsClients) _signupClient?.close();
        _signupClient = null;
        _ensureSession(key);
        return BlocProvider.value(
          value: _bloc!,
          child: ChatPage(
            // URL live (_apiUrl), bukan snapshot config saat startup:
            // pengguna bisa menggantinya dari Pengaturan/Signup, dan layar
            // harus menampilkan yang benar-benar dipakai klien.
            config: widget.config.copyWith(apiBaseUrl: _apiUrl),
            configProblem: widget.configProblem,
            voiceInput: widget.voiceInput,
            themeController: widget.themeController,
            llmSettings: widget.llmSettings,
            userProfile: widget.userProfile,
            auth: widget.auth,
            onApiBaseUrlChanged: (newUrl) => _adoptApiUrl(newUrl),
          ),
        );
      },
    );
  }
}
