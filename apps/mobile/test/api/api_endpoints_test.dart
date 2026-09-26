import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/api/api_endpoints.dart';
import 'package:wangsa_mobile/api/wangsa_api_client.dart';

http.Response _okAgent() => http.Response(
  jsonEncode({
    'success': true,
    'data': {'id': 'agent-1', 'name': 'Asisten', 'purpose': 'Membantu'},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _notFound() => http.Response(
  jsonEncode({
    'success': false,
    'error': {'code': 'NOT_FOUND', 'message': 'nope'},
  }),
  404,
  headers: {'content-type': 'application/json'},
);

WangsaApiClient _clientFor(
  String url,
  Map<String, http.Response Function()> byHost,
) => WangsaApiClient(
  baseUrl: url,
  requestTimeout: const Duration(seconds: 2),
  httpClient: MockClient((request) async {
    final handler = byHost[request.url.host];
    if (handler != null) return handler();
    throw Exception('host tak dikenal: ${request.url.host}');
  }),
);

void main() {
  group('buildApiCandidates', () {
    test('urutan: simpanan dulu, lalu localhost, lalu emulator', () {
      expect(buildApiCandidates(savedUrl: 'http://192.168.1.7:9901/'), [
        'http://192.168.1.7:9901',
        'http://localhost:9901',
        'http://10.0.2.2:9901',
      ]);
    });

    test('tanpa simpanan tetap ada fallback bawaan', () {
      expect(buildApiCandidates(), [
        'http://localhost:9901',
        'http://10.0.2.2:9901',
      ]);
    });

    test('port custom dari URL simpanan dipakai kandidat lokal', () {
      expect(buildApiCandidates(savedUrl: 'http://192.168.1.7:9797'), [
        'http://192.168.1.7:9797',
        'http://localhost:9797',
        'http://10.0.2.2:9797',
        'http://localhost:9901',
        'http://10.0.2.2:9901',
      ]);
    });

    test('alamat produk 9902 tetap jatuh balik ke gateway chat 9901', () {
      expect(buildApiCandidates(savedUrl: 'http://localhost:9902'), [
        'http://localhost:9902',
        'http://10.0.2.2:9902',
        'http://localhost:9901',
        'http://10.0.2.2:9901',
      ]);
    });

    test('duplikat dan nilai sampah dibuang', () {
      expect(
        buildApiCandidates(
          savedUrl: 'http://localhost:9901',
          envUrl: 'bukan-url',
        ),
        ['http://localhost:9901', 'http://10.0.2.2:9901'],
      );
    });
  });

  group('saved gateway URL migration', () {
    test('menolak alamat lama API produk 9902', () {
      expect(usableLegacyGatewaySavedUrl('http://localhost:9902'), isNull);
    });

    test('mempertahankan alamat gateway custom selain port produk', () {
      expect(
        usableLegacyGatewaySavedUrl('http://192.168.1.5:9797'),
        'http://192.168.1.5:9797',
      );
    });
  });

  group('adaptLoopbackApiUrl', () {
    test('mengubah loopback host laptop ke host emulator Android', () {
      expect(
        adaptLoopbackApiUrl('http://localhost:9901', androidEmulator: true),
        'http://10.0.2.2:9901',
      );
    });

    test('tidak mengubah alamat HP fisik atau alamat LAN', () {
      expect(
        adaptLoopbackApiUrl('http://localhost:9901', androidEmulator: false),
        'http://localhost:9901',
      );
      expect(
        adaptLoopbackApiUrl('http://192.168.1.5:9901', androidEmulator: true),
        'http://192.168.1.5:9901',
      );
    });
  });

  group('findReachableApiUrl', () {
    test('melewati yang mati, memakai yang hidup', () async {
      final found = await findReachableApiUrl(
        candidates: ['http://10.9.0.2:9901', 'http://localhost:9901'],
        agentId: 'agent-1',
        currentUrl: 'http://10.9.0.2:9901',
        clientFactory: (url) => _clientFor(url, {'localhost': _okAgent}),
      );

      expect(found, 'http://localhost:9901');
    });

    test('melewati URL yang sama dengan yang sedang dipakai', () async {
      var factoryCalls = 0;
      final found = await findReachableApiUrl(
        candidates: ['http://localhost:9901'],
        agentId: 'agent-1',
        currentUrl: 'http://localhost:9901/',
        clientFactory: (url) {
          factoryCalls++;
          return _clientFor(url, {'localhost': _okAgent});
        },
      );

      expect(found, isNull);
      expect(factoryCalls, 0);
    });

    test('server hidup tapi agent tak dikenal tetap dihitung hidup', () async {
      final found = await findReachableApiUrl(
        candidates: ['http://localhost:9901'],
        agentId: 'agent-salah',
        currentUrl: 'http://10.9.0.2:9901',
        clientFactory: (url) => _clientFor(url, {'localhost': _notFound}),
      );

      expect(found, 'http://localhost:9901');
    });

    test('semua mati mengembalikan null', () async {
      final found = await findReachableApiUrl(
        candidates: ['http://localhost:9901', 'http://10.0.2.2:9901'],
        agentId: 'agent-1',
        currentUrl: 'http://lain:9901',
        clientFactory: (url) => _clientFor(url, {}),
      );

      expect(found, isNull);
    });
  });

  group('diagnoseConnectionHint', () {
    test('localhost menunjuk backend + adb reverse', () {
      final hint = diagnoseConnectionHint('http://localhost:9901');

      expect(hint, contains('run_mobile_backend'));
      expect(hint, contains('adb reverse'));
    });

    test('10.0.2.2 dijelaskan khusus emulator', () {
      expect(
        diagnoseConnectionHint('http://10.0.2.2:9901'),
        contains('emulator'),
      );
    });

    test('IP LAN dijelaskan bisa basi karena DHCP', () {
      final hint = diagnoseConnectionHint('http://192.168.1.7:9901');

      expect(hint, contains('DHCP'));
      expect(hint, contains('localhost'));
    });
  });

  group('isPrivateLanIpv4', () {
    test('RFC1918 diterima', () {
      expect(isPrivateLanIpv4('10.0.0.1'), isTrue);
      expect(isPrivateLanIpv4('172.16.5.5'), isTrue);
      expect(isPrivateLanIpv4('172.31.255.254'), isTrue);
      expect(isPrivateLanIpv4('192.168.1.7'), isTrue);
    });

    test('loopback, link-local, CGNAT seluler, dan alamat publik ditolak', () {
      expect(isPrivateLanIpv4('127.0.0.1'), isFalse);
      expect(isPrivateLanIpv4('169.254.1.1'), isFalse);
      expect(isPrivateLanIpv4('100.74.245.201'), isFalse);
      expect(isPrivateLanIpv4('172.32.0.1'), isFalse);
      expect(isPrivateLanIpv4('8.8.8.8'), isFalse);
      expect(isPrivateLanIpv4('bukan-ip'), isFalse);
    });
  });

  group('lanProbeHosts', () {
    test('/24 membuang network & broadcast', () {
      final hosts = lanProbeHosts(address: '192.168.9.20', prefixLength: 24);

      expect(hosts, hasLength(254));
      expect(hosts.first, '192.168.9.1');
      expect(hosts.last, '192.168.9.254');
      expect(hosts, contains('192.168.9.20'));
      expect(hosts, isNot(contains('192.168.9.0')));
      expect(hosts, isNot(contains('192.168.9.255')));
    });

    test('subnet lebih lebar dari /24 dipadatkan ke /24 alamat lokal', () {
      final hosts = lanProbeHosts(address: '10.252.128.229', prefixLength: 21);

      expect(hosts, hasLength(254));
      expect(hosts.first, '10.252.128.1');
      expect(hosts.last, '10.252.128.254');
    });

    test('subnet lebih sempit dari /24 dipakai apa adanya', () {
      final hosts = lanProbeHosts(address: '192.168.9.20', prefixLength: 28);

      expect(hosts, hasLength(14));
      expect(hosts.first, '192.168.9.17');
      expect(hosts.last, '192.168.9.30');
    });

    test('alamat sampah menghasilkan daftar kosong', () {
      expect(lanProbeHosts(address: 'bukan-ip', prefixLength: 24), isEmpty);
      expect(lanProbeHosts(address: '999.1.1.1', prefixLength: 24), isEmpty);
      expect(lanProbeHosts(address: '192.168.1.1', prefixLength: 99), isEmpty);
    });
  });

  group('discoverLanBackendUrls', () {
    test(
      'hanya subnet privat yang dipindai; port terbuka diverifikasi HTTP',
      () async {
        final scanned = <String>{};
        final found = await discoverLanBackendUrls(
          listLocalIpv4: () async => [
            (address: '192.168.9.20', prefixLength: 24),
            // Seluler (CGNAT) + loopback: tidak boleh disentuh sama sekali.
            (address: '100.74.245.201', prefixLength: 24),
            (address: '127.0.0.1', prefixLength: 8),
          ],
          tcpProbe: (host, port, timeout) async {
            scanned.add(host);
            return host == '192.168.9.50';
          },
          clientFactory: (url) => _clientFor(url, {'192.168.9.50': _okAgent}),
        );

        expect(scanned, isNotEmpty);
        expect(scanned.every((h) => h.startsWith('192.168.9.')), isTrue);
        expect(
          scanned,
          isNot(contains('192.168.9.20')),
          reason: 'tidak memindai diri sendiri',
        );
        expect(found, ['http://192.168.9.50:9901']);
      },
    );

    test(
      'port terbuka tapi bukan Wangsa (RUNTIME_ERROR) tidak diadopsi',
      () async {
        final found = await discoverLanBackendUrls(
          listLocalIpv4: () async => [
            (address: '192.168.9.20', prefixLength: 24),
          ],
          tcpProbe: (host, port, timeout) async => host == '192.168.9.50',
          clientFactory: (url) => WangsaApiClient(
            baseUrl: url,
            requestTimeout: const Duration(seconds: 2),
            httpClient: MockClient((_) async => throw Exception('bukan JSON')),
          ),
        );

        expect(found, isEmpty);
      },
    );

    test('tanpa antarmuka privat: kosong dan tanpa pemindaian', () async {
      var probes = 0;
      final found = await discoverLanBackendUrls(
        listLocalIpv4: () async => [(address: '8.8.8.8', prefixLength: 32)],
        tcpProbe: (host, port, timeout) async {
          probes++;
          return true;
        },
      );

      expect(found, isEmpty);
      expect(probes, 0);
    });

    test('port custom dipakai di URL hasil', () async {
      final found = await discoverLanBackendUrls(
        port: 9797,
        listLocalIpv4: () async => [
          (address: '192.168.9.20', prefixLength: 24),
        ],
        tcpProbe: (host, port, timeout) async {
          expect(port, 9797);
          return host == '192.168.9.50';
        },
        clientFactory: (url) => _clientFor(url, {'192.168.9.50': _okAgent}),
      );

      expect(found, ['http://192.168.9.50:9797']);
    });
  });
}
