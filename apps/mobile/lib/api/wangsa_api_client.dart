import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../llm/llm_override.dart';
import 'api_result.dart';
import 'models.dart';

/// Klien untuk endpoint publik Wangsa.
///
/// Tidak pernah mengirim header identitas maupun workspace. Agent yang
/// sudah dipublikasikan memang dapat dijangkau tanpa kredensial builder,
/// dan mengirim identitas pengembang dari aplikasi yang bisa dibuka
/// siapa saja akan sia-sia sekaligus menyesatkan. Ini cerminan
/// `publicRequest` di klien web.
///
/// Panjang pesan maksimum dicek di sini supaya pengguna tidak menunggu
/// satu perjalanan bolak-balik hanya untuk ditolak. Server tetap yang
/// berwenang.
class WangsaApiClient {
  static const int maxMessageLength = 4000;

  String baseUrl;

  /// Bearer token milik user ini (dari signup / layar token). Null berarti
  /// belum daftar — server localhost-terbuka tetap bisa dijangkau tanpa ini,
  /// tapi gateway multiplex menolak request profile tanpa token valid.
  String? authToken;

  void updateBaseUrl(String newUrl) {
    baseUrl = _trimTrailingSlash(newUrl);
  }

  void updateToken(String? newToken) {
    final v = newToken?.trim();
    authToken = (v == null || v.isEmpty) ? null : v;
  }

  Map<String, String> _authHeaders([Map<String, String>? extra]) {
    final headers = <String, String>{...?extra};
    final token = authToken;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  http.Client _httpClient;

  /// Batas tunggu untuk permintaan biasa, misalnya memuat Agent.
  ///
  /// Paket `http` tidak punya batas waktu bawaan. Tanpa ini, alamat yang
  /// tidak bisa dijangkau di perangkat sungguhan membuat koneksi
  /// menggantung beberapa menit, dan layar terjebak di "memuat" tanpa
  /// pernah menunjukkan galat.
  final Duration requestTimeout;

  /// Batas tunggu balasan Agent, sengaja jauh lebih panjang. Balasan
  /// melewati runtime Agent dan LLM di Bifrost, yang terukur memakan
  /// puluhan detik (lihat `evaluation/comparison.md`), jadi batas yang
  /// sama dengan [requestTimeout] akan memotong balasan yang sebenarnya
  /// sedang dalam perjalanan.
  ///
  /// 300 detik, dan bukan kebetulan — ini menyamai bawaan
  /// `WANGSA_MOBILE_REPLY_TIMEOUT` di `plugins/platforms/wangsa_mobile/
  /// adapter.py`. Giliran dengan beberapa panggilan tool (delegasi,
  /// screenshot, kerja terminal bertahap) rutin memakan lebih dari 120
  /// detik; kalau klien menyerah lebih dulu dari server, pengguna melihat
  /// "Tidak bisa menghubungi API Wangsa" padahal Agent masih bekerja dan
  /// akan menjawab. Ubah bersamaan dengan nilai di server, jangan sendiri.
  final Duration replyTimeout;

  WangsaApiClient({
    required String baseUrl,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 15),
    this.replyTimeout = const Duration(seconds: 300),
  }) : baseUrl = _trimTrailingSlash(baseUrl),
       _httpClient = httpClient ?? http.Client();

  static String _trimTrailingSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  /// Pendaftaran terbuka: buat profile + terbitkan token (`POST /api/v1/auth/signup`).
  /// Tetap publik tanpa token lama — ini pintu masuk user baru.
  Future<ApiResult<SignupResult>> signup(String username) {
    final uri = Uri.parse('$baseUrl/api/v1/auth/signup');
    return _send(
      () => _httpClient.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username.trim().toLowerCase()}),
      ),
      SignupResult.fromJson,
      requestTimeout,
    );
  }

  /// Identitas pemanggil + status LLM (`GET /api/v1/auth/me`, butuh token).
  Future<ApiResult<MeInfo>> getMe() {
    final uri = Uri.parse('$baseUrl/api/v1/auth/me');
    return _send(
      () => _httpClient.get(uri, headers: _authHeaders()),
      MeInfo.fromJson,
      requestTimeout,
    );
  }

  /// Ringkasan budget spend profile (`GET /api/v1/auth/budget`, butuh token).
  Future<ApiResult<BudgetInfo>> getBudget() {
    final uri = Uri.parse('$baseUrl/api/v1/auth/budget');
    return _send(
      () => _httpClient.get(uri, headers: _authHeaders()),
      BudgetInfo.fromJson,
      requestTimeout,
    );
  }

  /// Cabut token sendiri / logout (`DELETE /api/v1/auth/token`, butuh token).
  /// Sukses berarti server menghapus token — klien wajib membuang token lokal.
  Future<ApiResult<bool>> revokeToken() {
    final uri = Uri.parse('$baseUrl/api/v1/auth/token');
    return _send(
      () => _httpClient.delete(uri, headers: _authHeaders()),
      (json) => (json['revoked'] as bool?) ?? true,
      requestTimeout,
    );
  }

  Future<ApiResult<PublicAgent>> getAgent(String agentId) {
    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}',
    );
    return _send(
      () => _httpClient.get(uri, headers: _authHeaders()),
      PublicAgent.fromJson,
      requestTimeout,
    );
  }

  /// Daftar model deployment dari `GET /api/v1/agents/:agentId/models`.
  /// Gagal di sini tidak fatal — pemanggil memakai bawaan server.
  Future<ApiResult<ModelOptions>> getModels(String agentId) {
    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/models',
    );
    return _send(
      () => _httpClient.get(uri, headers: _authHeaders()),
      ModelOptions.fromJson,
      requestTimeout,
    );
  }

  /// Daftar sesi aktif untuk drawer percakapan.
  Future<ApiResult<List<SessionSummary>>> getSessions(String agentId) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/sessions',
    );
    return _send(() => _httpClient.get(uri, headers: _authHeaders()), (json) {
      final list = json['sessions'];
      if (list is List) {
        return [
          for (final item in list)
            if (item is Map<String, dynamic>) SessionSummary.fromJson(item),
        ];
      }
      return <SessionSummary>[];
    }, requestTimeout);
  }

  /// Ambil transkrip tersimpan satu sesi lampau, dipakai saat pengguna
  /// beralih sesi dari drawer supaya layar tidak tiba-tiba kosong padahal
  /// percakapan di server masih ada.
  Future<ApiResult<List<HistoryTurn>>> getSessionMessages(
    String agentId,
    String sessionId,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/sessions/${Uri.encodeComponent(sessionId)}/messages',
    );
    return _send(() => _httpClient.get(uri, headers: _authHeaders()), (json) {
      final list = json['turns'];
      if (list is List) {
        return [
          for (final item in list)
            if (item is Map<String, dynamic>) HistoryTurn.fromJson(item),
        ];
      }
      return <HistoryTurn>[];
    }, requestTimeout);
  }

  /// Hapus riwayat sesi di server.
  Future<ApiResult<bool>> deleteSession(
    String agentId,
    String sessionId,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/sessions/${Uri.encodeComponent(sessionId)}',
    );
    return _send(
      () => _httpClient.delete(uri, headers: _authHeaders()),
      (json) => json['deleted'] as bool? ?? true,
      requestTimeout,
    );
  }

  /// Ambil daftar provider AI dan status autentikasinya dari server.
  Future<ApiResult<List<AuthProviderItem>>> getAuthProviders() async {
    final uri = Uri.parse('$baseUrl/api/v1/auth/providers');
    return _send(() => _httpClient.get(uri, headers: _authHeaders()), (json) {
      final list = json['providers'];
      if (list is List) {
        return [
          for (final item in list)
            if (item is Map<String, dynamic>) AuthProviderItem.fromJson(item),
        ];
      }
      return <AuthProviderItem>[];
    }, requestTimeout);
  }

  /// Simpan kredensial untuk provider AI tertentu di server.
  Future<ApiResult<String>> saveProviderCredentials(
    String providerId, {
    String? apiKey,
    String? token,
    String? name,
    String? baseUrl,
    String? model,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/auth/providers/${Uri.encodeComponent(providerId)}',
    );
    final body = jsonEncode({
      'apiKey': ?apiKey,
      'token': ?token,
      'name': ?name,
      'baseUrl': ?baseUrl,
      'model': ?model,
    });
    return _send(
      () => _httpClient.post(
        uri,
        headers: _authHeaders({'Content-Type': 'application/json'}),
        body: body,
      ),
      (json) => json['message'] as String? ?? 'Berhasil disimpan',
      requestTimeout,
    );
  }

  /// Hapus kredensial provider AI dari server.
  Future<ApiResult<String>> deleteProviderCredentials(String providerId) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/auth/providers/${Uri.encodeComponent(providerId)}',
    );
    return _send(
      () => _httpClient.delete(uri, headers: _authHeaders()),
      (json) => json['message'] as String? ?? 'Berhasil dihapus',
      requestTimeout,
    );
  }

  /// Memulai OAuth Device Flow untuk GitHub Copilot.
  Future<ApiResult<Map<String, dynamic>>> startCopilotDeviceCode() async {
    final uri = Uri.parse('$baseUrl/api/v1/auth/copilot/device-code');
    return _send(
      () => _httpClient.post(uri, headers: _authHeaders()),
      (json) => json,
      requestTimeout,
    );
  }

  /// Polling status GitHub Copilot Device Flow.
  Future<ApiResult<Map<String, dynamic>>> pollCopilotDeviceCode(
    String deviceCode,
  ) async {
    final uri = Uri.parse('$baseUrl/api/v1/auth/copilot/poll');
    return _send(
      () => _httpClient.post(
        uri,
        headers: _authHeaders({'Content-Type': 'application/json'}),
        body: jsonEncode({'device_code': deviceCode}),
      ),
      (json) => json,
      requestTimeout,
    );
  }

  /// [model] null berarti memakai model aktif sesi di server (bawaan
  /// deployment sampai pengguna memilih lain lewat pemilih model).
  /// Non-null memilih model itu untuk sesi ini — server memvalidasinya
  /// terhadap katalog provider yang sedang aktif.
  ///
  /// [images] gambar yang dibaca ke memori, dikirim sebagai base64.
  /// Pesan teks boleh kosong bila ada gambar (pesan foto tanpa caption).
  ///
  /// [llm] tidak dipakai lagi (BYOK untuk backend lama yang sudah tidak
  /// ada) — dipertahankan supaya pemanggil lama tetap kompilasi, nilainya
  /// tetap dikirim apa adanya dan diabaikan server.
  ///
  /// [sessionId] null pada pesan pertama percakapan; server akan
  /// menerbitkan satu dan mengembalikannya lewat [AgentReply.sessionId].
  /// Pemanggil wajib mengirim balik nilai itu pada pesan berikutnya di
  /// percakapan yang sama — tanpanya server memperlakukan setiap pesan
  /// sebagai percakapan baru.
  ///
  /// [userName] dan [userBio] berasal dari profil lokal pengguna (lihat
  /// `UserProfileController`) — nama panggilan dan preferensi singkat
  /// (gaya bicara, bahasa, dll.). Keduanya opsional; kosong berarti Agent
  /// memakai identitas bawaan "mobile" seperti sebelum profil ada.
  Future<ApiResult<AgentReply>> sendMessage(
    String agentId,
    String message, {
    LlmOverride? llm,
    String? model,
    String? provider,
    List<ChatImage>? images,
    String? sessionId,
    String? userName,
    String? userBio,
    List<String> toolsets = const [],
    void Function(ToolCallInfo activity)? onActivity,
    void Function(String delta)? onDelta,
  }) {
    final lampiran = images ?? const <ChatImage>[];
    if (message.trim().isEmpty && lampiran.isEmpty) {
      return Future.value(
        const ApiResult<AgentReply>.failure(
          ApiError('VALIDATION_ERROR', 'Pesan tidak boleh kosong.'),
        ),
      );
    }

    if (message.length > maxMessageLength) {
      return Future.value(
        const ApiResult<AgentReply>.failure(
          ApiError('VALIDATION_ERROR', 'Pesan terlalu panjang.'),
        ),
      );
    }

    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/messages/stream',
    );
    final body = <String, Object?>{
      'message': message,
      'toolsets': toolsets,
      if (llm != null) 'llm': llm.toJson(),
      if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
      if (provider != null && provider.trim().isNotEmpty)
        'provider': provider.trim(),
      if (lampiran.isNotEmpty)
        'images': [
          for (final img in lampiran)
            {
              'data': base64Encode(img.bytes),
              'mimeType': img.mimeType,
              'filename': img.filename,
            },
        ],
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      if (userName != null && userName.trim().isNotEmpty)
        'userName': userName.trim(),
      if (userBio != null && userBio.trim().isNotEmpty)
        'userBio': userBio.trim(),
    };
    return _sendStreamingMessage(uri, body, onActivity, onDelta);
  }

  /// Kirim rekaman ponsel ke STT provider yang dikonfigurasi di backend.
  Future<ApiResult<String>> transcribeAudio(
    Uint8List bytes, {
    String mimeType = 'audio/mp4',
  }) async {
    try {
      final request =
          http.Request('POST', Uri.parse('$baseUrl/api/v1/audio/transcribe'))
            ..headers.addAll(_authHeaders({'content-type': mimeType}))
            ..bodyBytes = bytes;
      final response = await _httpClient.send(request).timeout(replyTimeout);
      final body = await response.stream.bytesToString();
      final decoded = jsonDecode(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return ApiResult.fromEnvelope<String>(decoded, (_) => '');
      }
      return ApiResult.fromEnvelope<String>(
        decoded,
        (data) => data['transcript'] as String? ?? '',
      );
    } catch (_) {
      return ApiResult.runtimeError('Tidak bisa mengirim audio ke STT Wangsa.');
    }
  }

  /// Minta backend membuat audio balasan melalui provider TTS terpilih.
  Future<ApiResult<SpokenAudio>> speakText(String text) async {
    try {
      final request =
          http.Request('POST', Uri.parse('$baseUrl/api/v1/audio/speak'))
            ..headers.addAll(_authHeaders({'content-type': 'application/json'}))
            ..body = jsonEncode({'text': text});
      final response = await _httpClient.send(request).timeout(replyTimeout);
      final mimeType = response.headers['content-type'] ?? 'audio/mpeg';
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        try {
          return ApiResult.fromEnvelope<SpokenAudio>(
            jsonDecode(body),
            (_) => throw const FormatException(),
          );
        } catch (_) {
          return ApiResult.runtimeError('TTS Wangsa gagal membuat audio.');
        }
      }
      return ApiResult.success(
        SpokenAudio(bytes: await response.stream.toBytes(), mimeType: mimeType),
      );
    } catch (_) {
      return ApiResult.runtimeError(
        'Tidak bisa meminta audio dari TTS Wangsa.',
      );
    }
  }

  Future<ApiResult<AgentReply>> _sendStreamingMessage(
    Uri uri,
    Map<String, Object?> body,
    void Function(ToolCallInfo activity)? onActivity,
    void Function(String delta)? onDelta,
  ) async {
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(
          _authHeaders(const {
            'content-type': 'application/json; charset=utf-8',
            'accept': 'text/event-stream, application/json',
          }),
        )
        ..body = jsonEncode(body);
      final response = await _httpClient.send(request).timeout(replyTimeout);
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('text/event-stream')) {
        final text = await response.stream.bytesToString().timeout(
          replyTimeout,
        );
        try {
          return ApiResult.fromEnvelope<AgentReply>(
            jsonDecode(text),
            AgentReply.fromJson,
          );
        } catch (_) {
          return ApiResult.runtimeError('Balasan API tidak bisa dibaca.');
        }
      }

      String eventName = '';
      final eventData = StringBuffer();
      ApiResult<AgentReply>? result;

      void dispatchEvent() {
        final raw = eventData.toString().trim();
        if (raw.isEmpty) return;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic>) return;
          switch (eventName) {
            case 'tool':
              onActivity?.call(ToolCallInfo.fromJson(decoded));
              break;
            case 'delta':
              final delta = decoded['text'];
              if (delta is String && delta.isNotEmpty) onDelta?.call(delta);
              break;
            case 'done':
              result = ApiResult<AgentReply>.success(
                AgentReply.fromJson(decoded),
              );
              break;
            case 'error':
              result = ApiResult<AgentReply>.failure(
                ApiError(
                  decoded['code'] as String? ?? 'RUNTIME_ERROR',
                  decoded['message'] as String? ??
                      'Agent gagal memproses pesan.',
                ),
              );
              break;
          }
        } catch (_) {
          result = ApiResult.runtimeError('Event aktivitas tidak bisa dibaca.');
        }
        eventName = '';
        eventData.clear();
      }

      final deadline = DateTime.now().add(replyTimeout);
      final lines = StreamIterator<String>(
        response.stream.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        while (true) {
          final remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) {
            throw TimeoutException('Agent reply timed out.');
          }
          if (!await lines.moveNext().timeout(remaining)) break;
          final line = lines.current;
          if (line.isEmpty) {
            dispatchEvent();
          } else if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventData.isNotEmpty) eventData.write('\n');
            eventData.write(line.substring(5).trimLeft());
          }
          // `done` and `error` are terminal protocol events. Cancel the
          // response subscription now instead of waiting for the server to
          // close a keep-alive SSE connection before updating the chat UI.
          if (result != null) break;
        }
        dispatchEvent();
      } finally {
        await lines.cancel();
      }
      return result ?? ApiResult.runtimeError('Aliran balasan terputus.');
    } on TimeoutException {
      return ApiResult.runtimeError('Wangsa belum membalas. Coba lagi.');
    } catch (_) {
      return ApiResult.runtimeError('Tidak bisa menghubungi API Wangsa.');
    }
  }

  /// Satu-satunya tempat lemparan menjadi [ApiResult].
  ///
  /// Jaringan mati, nama host tidak terselesaikan, server yang tidak
  /// menjawab sampai batas waktu, atau badan balasan
  /// yang bukan JSON, misalnya halaman galat dari proxy, semuanya
  /// berakhir sebagai RUNTIME_ERROR, bukan lemparan yang harus ditangkap
  /// pemanggil.
  Future<ApiResult<T>> _send<T>(
    Future<http.Response> Function() call,
    T Function(Map<String, dynamic>) parse,
    Duration timeout,
  ) async {
    try {
      final response = await call().timeout(timeout);
      final result = () {
        try {
          return ApiResult.fromEnvelope<T>(jsonDecode(response.body), parse);
        } catch (_) {
          return ApiResult.runtimeError<T>('Balasan API tidak bisa dibaca.');
        }
      }();
      if (result.isSuccess) return result;
      final err = result.errorOrNull;
      if (err == null) return result;
      // Pesan ramah untuk galat auth yang sering ditemui user baru.
      // Kode asli dipertahankan supaya pemanggil bisa membedakan 401/429/503.
      switch (err.code) {
        case 'UNAUTHORIZED':
          return ApiResult<T>.failure(
            ApiError(
              err.code,
              'Token tidak valid atau kedaluwarsa. Daftar lagi atau masukkan token.',
            ),
          );
        case 'PROFILE_UNAVAILABLE':
          return ApiResult<T>.failure(
            ApiError(
              err.code,
              'Profil belum siap di backend. Coba lagi sebentar atau hubungi admin.',
            ),
          );
        case 'RATE_LIMITED':
          return ApiResult<T>.failure(
            ApiError(
              err.code,
              'Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi.',
            ),
          );
        case 'CONFLICT':
          return result;
        default:
          return result;
      }
    } catch (_) {
      return ApiResult.runtimeError<T>('Tidak bisa menghubungi API Wangsa.');
    }
  }

  void close() => _httpClient.close();

  /// Membatalkan permintaan yang sedang berjalan (dipakai tombol
  /// "berhenti" waktu Agent sedang membalas) dengan menutup klien HTTP
  /// yang dipakainya — `http.Client` tidak punya pembatalan per-permintaan,
  /// menutup klien adalah satu-satunya cara memutus koneksi yang sedang
  /// berjalan. Klien lama diganti yang baru sesudahnya, supaya panggilan
  /// berikutnya (pesan selanjutnya) tetap bisa jalan, bukan macet
  /// selamanya seperti kalau [close] biasa yang dipanggil.
  void cancelInFlight() {
    _httpClient.close();
    _httpClient = http.Client();
  }
}
