import 'dart:convert';

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

  final String baseUrl;
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
  })  : baseUrl = _trimTrailingSlash(baseUrl),
        _httpClient = httpClient ?? http.Client();

  static String _trimTrailingSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  Future<ApiResult<PublicAgent>> getAgent(String agentId) {
    final uri = Uri.parse('$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}');
    return _send(() => _httpClient.get(uri), PublicAgent.fromJson, requestTimeout);
  }

  /// Daftar model deployment dari `GET /api/v1/agents/:agentId/models`.
  /// Gagal di sini tidak fatal — pemanggil memakai bawaan server.
  Future<ApiResult<ModelOptions>> getModels(String agentId) {
    final uri = Uri.parse('$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/models');
    return _send(() => _httpClient.get(uri), ModelOptions.fromJson, requestTimeout);
  }

  /// Daftar sesi aktif untuk drawer percakapan.
  Future<ApiResult<List<SessionSummary>>> getSessions(String agentId) async {
    final uri = Uri.parse('$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/sessions');
    return _send(
      () => _httpClient.get(uri),
      (json) {
        final list = json['sessions'];
        if (list is List) {
          return [
            for (final item in list)
              if (item is Map<String, dynamic>) SessionSummary.fromJson(item),
          ];
        }
        return <SessionSummary>[];
      },
      requestTimeout,
    );
  }

  /// Hapus riwayat sesi di server.
  Future<ApiResult<bool>> deleteSession(String agentId, String sessionId) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/sessions/${Uri.encodeComponent(sessionId)}',
    );
    return _send(
      () => _httpClient.delete(uri),
      (json) => json['deleted'] as bool? ?? true,
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
  Future<ApiResult<AgentReply>> sendMessage(
    String agentId,
    String message, {
    LlmOverride? llm,
    String? model,
    List<ChatImage>? images,
    String? sessionId,
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

    final uri = Uri.parse('$baseUrl/api/v1/agents/${Uri.encodeComponent(agentId)}/messages');
    final body = <String, Object?>{
      'message': message,
      if (llm != null) 'llm': llm.toJson(),
      if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
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
    };
    return _send(
      () => _httpClient.post(
        uri,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        body: jsonEncode(body),
      ),
      AgentReply.fromJson,
      replyTimeout,
    );
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
      try {
        return ApiResult.fromEnvelope<T>(jsonDecode(response.body), parse);
      } catch (_) {
        return ApiResult.runtimeError<T>('Balasan API tidak bisa dibaca.');
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
