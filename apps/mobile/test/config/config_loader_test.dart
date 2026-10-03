import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/config/app_config.dart';
import 'package:wangsa_mobile/config/config_loader.dart';

const fallback = AppConfig(
  apiBaseUrl: 'http://localhost:3001',
  defaultAgentId: 'cadangan',
);

ConfigLoader loaderYangMenjawab(http.Response Function() jawab) => ConfigLoader(
  configUrl: Uri.parse('https://wangsa.test/config.json'),
  fallback: fallback,
  httpClient: MockClient((_) async => jawab()),
);

void main() {
  test('memakai konfigurasi dari server bila sah', () async {
    final loader = loaderYangMenjawab(
      () => http.Response(
        jsonEncode({
          'apiBaseUrl': 'https://api.wangsa.test',
          'defaultAgentId': 'agent-1',
        }),
        200,
      ),
    );

    final result = await loader.load();

    expect(result.usedFallback, isFalse);
    expect(result.config.apiBaseUrl, 'https://api.wangsa.test');
    expect(result.config.defaultAgentId, 'agent-1');
  });

  test('jatuh ke cadangan bila berkas tidak terjangkau', () async {
    final loader = ConfigLoader(
      configUrl: Uri.parse('https://wangsa.test/config.json'),
      fallback: fallback,
      httpClient: MockClient((_) async => throw Exception('mati')),
    );

    final result = await loader.load();

    expect(result.usedFallback, isTrue);
    expect(result.config.defaultAgentId, 'cadangan');
    expect(result.problem, isNotNull);
  });

  test(
    'jatuh ke cadangan bila isinya tidak sah, dengan alasan yang tercatat',
    () async {
      final loader = loaderYangMenjawab(
        () => http.Response(jsonEncode({'defaultAgentId': 'agent-1'}), 200),
      );

      final result = await loader.load();

      expect(result.usedFallback, isTrue);
      expect(result.problem, contains('apiBaseUrl'));
    },
  );

  test('jatuh ke cadangan bila status bukan 200', () async {
    final loader = loaderYangMenjawab(() => http.Response('nope', 404));

    final result = await loader.load();

    expect(result.usedFallback, isTrue);
    expect(result.problem, contains('404'));
  });
}
