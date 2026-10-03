import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'product_models.dart';

class ProductApiException implements Exception {
  final String code;
  final String message;
  const ProductApiException(this.code, this.message);
  bool get isUnauthorized => code == 'UNAUTHORIZED' || code == 'INVALID_TOKEN';
  bool get uncertain => code == 'NETWORK_ERROR' || code == 'INVALID_RESPONSE';
  @override
  String toString() => message;
}

/// Credentials are sent only to this explicitly configured origin. A redirect
/// is never followed, and a failed request never discovers a different server.
class ProductApi {
  final String baseUrl;
  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;
  String? token;

  ProductApi({
    required String baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    bool allowInsecureLocal = kDebugMode,
  }) : baseUrl = normalizeUrl(baseUrl, allowInsecureLocal: allowInsecureLocal),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  static String normalizeUrl(
    String value, {
    bool allowInsecureLocal = kDebugMode,
  }) {
    final uri = Uri.tryParse(value.trim());
    final local =
        uri != null &&
        const ['localhost', '127.0.0.1', '::1', '10.0.2.2'].contains(uri.host);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' &&
            !(allowInsecureLocal && local && uri.scheme == 'http'))) {
      throw const ProductApiException(
        'INVALID_SERVER',
        'Gunakan alamat server HTTPS. HTTP lokal hanya tersedia untuk pengembangan.',
      );
    }
    return uri.origin;
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    String? idempotencyKey,
  }) async {
    final request =
        http.Request(method, Uri.parse('$baseUrl/api/mobile/v1$path'))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await (() async => http.Response.fromStream(
        await _http.send(request),
      ))().timeout(timeout);
      if (response.statusCode == 401) {
        throw const ProductApiException(
          'UNAUTHORIZED',
          'Sesi berakhir. Masuk lagi untuk melanjutkan.',
        );
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const ProductApiException(
          'INVALID_SERVER',
          'Server mengalihkan permintaan. Periksa alamat server.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const ProductApiException(
          'INVALID_RESPONSE',
          'Balasan server tidak bisa dibaca. Coba lagi.',
        );
      }
      if (response.statusCode >= 400 || decoded['error'] != null) {
        final error = decoded['error'];
        throw ProductApiException(
          error is Map
              ? error['code'] as String? ?? 'REQUEST_FAILED'
              : 'REQUEST_FAILED',
          error is Map
              ? error['message'] as String? ?? 'Permintaan gagal. Coba lagi.'
              : 'Permintaan gagal. Coba lagi.',
        );
      }
      return decoded['data'];
    } on ProductApiException {
      rethrow;
    } on FormatException {
      throw const ProductApiException(
        'INVALID_RESPONSE',
        'Balasan server tidak bisa dibaca. Coba lagi.',
      );
    } catch (_) {
      throw const ProductApiException(
        'NETWORK_ERROR',
        'Koneksi terputus. Periksa internet lalu coba lagi.',
      );
    }
  }

  Future<({String token, ProductUser user})> authenticate(
    String action,
    String username,
    String password,
  ) async {
    final data = await _request(
      'POST',
      '/auth/$action',
      body: {'username': username, 'password': password},
    );
    return (
      token: data['token'] as String,
      user: ProductUser.fromJson(Map<String, dynamic>.from(data['user'])),
    );
  }

  Future<ProductUser> me() async => ProductUser.fromJson(
    Map<String, dynamic>.from(await _request('GET', '/auth/me')),
  );
  Future<void> logout() async {
    await _request('POST', '/auth/logout');
  }

  Future<ProductProvider> provider() async => ProductProvider.fromJson(
    Map<String, dynamic>.from(await _request('GET', '/provider')),
  );
  Future<List<ProductProviderOption>> providerCatalog() async => [
    for (final item in await _request('GET', '/provider/catalog') as List)
      ProductProviderOption.fromJson(Map<String, dynamic>.from(item)),
  ];
  Future<ProductModelCatalog> discoverModels(
    String provider, {
    String apiKey = '',
  }) async => ProductModelCatalog.fromJson(
    Map<String, dynamic>.from(
      await _request(
        'POST',
        '/provider/models',
        body: {'provider': provider, 'api_key': apiKey},
      ),
    ),
  );
  Future<void> saveProvider(
    String provider,
    String model,
    String apiKey,
  ) async {
    await _request(
      'PUT',
      '/provider',
      body: {'provider': provider, 'model': model, 'api_key': apiKey},
    );
  }

  Future<void> deleteProvider() async {
    await _request('DELETE', '/provider');
  }

  Future<List<ProductJob>> jobs() async => [
    for (final item in await _request('GET', '/jobs') as List)
      ProductJob.fromJson(Map<String, dynamic>.from(item)),
  ];
  Future<ProductJob> job(String id) async => ProductJob.fromJson(
    Map<String, dynamic>.from(
      await _request('GET', '/jobs/${Uri.encodeComponent(id)}'),
    ),
  );
  Future<ProductJob> createJob(
    String title,
    String prompt,
    String key, {
    String? skillId,
    Map<String, String> browserSecrets = const {},
  }) async => ProductJob.fromJson(
    Map<String, dynamic>.from(
      await _request(
        'POST',
        '/jobs',
        body: {
          'title': title,
          'prompt': prompt,
          'skill_id': ?skillId,
          'browser_secrets': browserSecrets,
        },
        idempotencyKey: key,
      ),
    ),
  );
  Future<ProductJob> reply(String id, String message, String key) async =>
      ProductJob.fromJson(
        Map<String, dynamic>.from(
          await _request(
            'POST',
            '/jobs/${Uri.encodeComponent(id)}/reply',
            body: {'message': message},
            idempotencyKey: key,
          ),
        ),
      );
  Future<ProductJob> cancel(String id) async => ProductJob.fromJson(
    Map<String, dynamic>.from(
      await _request('POST', '/jobs/${Uri.encodeComponent(id)}/cancel'),
    ),
  );
  Future<ProductBlueprint> blueprint(String id) async => ProductBlueprint.fromJson(
    Map<String, dynamic>.from(await _request('GET', '/jobs/${Uri.encodeComponent(id)}/blueprint'))['current'] as Map<String, dynamic>,
  );
  Future<ProductJob> approve(String id, String hash, String key) async => ProductJob.fromJson(
    Map<String, dynamic>.from(await _request(
      'POST', '/jobs/${Uri.encodeComponent(id)}/approve',
      body: {'blueprint_hash': hash}, idempotencyKey: key,
    )),
  );

  Future<List<ProductSkill>> skills() async => [
    for (final item in await _request('GET', '/skills') as List)
      ProductSkill.fromJson(Map<String, dynamic>.from(item)),
  ];
  Future<void> activate(String id) async {
    await _request('POST', '/skills/${Uri.encodeComponent(id)}/activate');
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}
