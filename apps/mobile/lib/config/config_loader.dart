import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';

/// Mengambil berkas konfigurasi dari server saat aplikasi dibuka.
///
/// Bila berkas itu tidak terjangkau atau isinya tidak sah, aplikasi
/// jatuh ke [fallback] agar tetap bisa dipakai, dan alasannya dicatat di
/// [ConfigLoadResult.problem] supaya layar pengaturan bisa menunjukkan
/// apa yang terjadi. Diam-diam memakai nilai bawaan tanpa jejak adalah
/// cara tercepat membuat orang mengejar galat yang salah.
class ConfigLoader {
  final Uri configUrl;
  final AppConfig fallback;
  final http.Client _httpClient;
  final Duration timeout;

  ConfigLoader({
    required this.configUrl,
    required this.fallback,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
  }) : _httpClient = httpClient ?? http.Client();

  Future<ConfigLoadResult> load() async {
    try {
      final response = await _httpClient.get(configUrl).timeout(timeout);

      if (response.statusCode != 200) {
        return ConfigLoadResult(
          config: fallback,
          problem: 'Berkas konfigurasi menjawab ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return ConfigLoadResult(
          config: fallback,
          problem: 'Isi berkas konfigurasi bukan objek JSON.',
        );
      }

      return ConfigLoadResult(config: AppConfig.fromJson(decoded));
    } on FormatException catch (error) {
      return ConfigLoadResult(config: fallback, problem: error.message);
    } catch (_) {
      return ConfigLoadResult(
        config: fallback,
        problem: 'Berkas konfigurasi tidak bisa dijangkau.',
      );
    }
  }
}

class ConfigLoadResult {
  final AppConfig config;

  /// Null bila konfigurasi benar-benar datang dari server.
  final String? problem;

  const ConfigLoadResult({required this.config, this.problem});

  bool get usedFallback => problem != null;
}
