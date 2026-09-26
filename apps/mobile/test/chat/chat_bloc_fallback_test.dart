import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/api/wangsa_api_client.dart';
import 'package:wangsa_mobile/chat/bloc/chat_bloc.dart';

http.Response _agentOk() => http.Response(
      jsonEncode({
        'success': true,
        'data': {'id': 'agent-1', 'name': 'Asisten', 'purpose': 'Membantu'},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _meOk() => http.Response(
      jsonEncode({
        'success': true,
        'data': {'profile': 'test', 'configured': true},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _modelsEmpty() => http.Response(
      jsonEncode({
        'success': true,
        'data': {'provider': '', 'current': '', 'models': [], 'providers': []},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Klien utama menembak host basi (selalu lempar → RUNTIME_ERROR),
/// kandidat probing menjawab sesuai [liveHosts].
WangsaApiClient _probingClient(String baseUrl, Set<String> liveHosts) =>
    ChatBlocProbeHarness.clientFor(
      baseUrl: baseUrl,
      liveHosts: liveHosts,
    );

/// Helper kecil agar konstruksi MockClient per-URL seragam antara test.
abstract class ChatBlocProbeHarness {
  static WangsaApiClient clientFor({
    required String baseUrl,
    required Set<String> liveHosts,
  }) =>
      WangsaApiClient(
        baseUrl: baseUrl,
        httpClient: MockClient((request) async {
          if (!liveHosts.contains(request.url.host)) {
            throw Exception('host mati: ${request.url.host}');
          }
          final path = request.url.path;
          if (path.endsWith('/api/v1/auth/me')) return _meOk();
          if (path.endsWith('/models')) return _modelsEmpty();
          return _agentOk();
        }),
      );

  static WangsaApiClient Function(String url) factoryFor(Set<String> liveHosts) =>
      (url) => clientFor(baseUrl: url, liveHosts: liveHosts);
}

void main() {
  group('ChatBloc fallback koneksi', () {
    final resolved = <String>[];

    blocTest<ChatBloc, ChatState>(
      'URL basi pulih sendiri ke kandidat hidup dan melaporkannya',
      build: () => ChatBloc(
        apiClient: _probingClient('http://10.9.23.171:9901', {'localhost'}),
        agentId: 'agent-1',
        candidateUrls: const [
          'http://10.9.23.171:9901',
          'http://localhost:9901',
          'http://10.0.2.2:9901',
        ],
        probeTimeout: const Duration(seconds: 2),
        clientFactory: ChatBlocProbeHarness.factoryFor({'localhost'}),
        onApiBaseUrlResolved: resolved.add,
      ),
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>()
            .having((s) => s.status, 'status', ChatStatus.ready)
            .having((s) => s.agent?.name, 'nama agent', 'Asisten'),
        isA<ChatState>().having((s) => s.isCheckingSetup, 'cek setup', isTrue),
        isA<ChatState>()
            .having((s) => s.profileName, 'profile', 'test')
            .having((s) => s.needsSetup, 'needsSetup', isFalse),
      ],
      verify: (bloc) {
        expect(bloc.apiClient.baseUrl, 'http://localhost:9901');
        expect(resolved, ['http://localhost:9901']);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'semua kandidat mati: gagal dengan petunjuk spesifik-host',
      build: () => ChatBloc(
        apiClient: _probingClient('http://localhost:9901', {}),
        agentId: 'agent-1',
        candidateUrls: const [
          'http://localhost:9901',
          'http://10.0.2.2:9901',
        ],
        probeTimeout: const Duration(seconds: 2),
        clientFactory: ChatBlocProbeHarness.factoryFor({}),
      ),
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>()
            .having((s) => s.status, 'status', ChatStatus.failed)
            .having((s) => s.errorMessage, 'ada petunjuk', contains('adb reverse')),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'tanpa kandidat: perilaku lama, langsung gagal tanpa probing',
      build: () => ChatBloc(
        apiClient: _probingClient('http://localhost:9901', {}),
        agentId: 'agent-1',
      ),
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.failed),
      ],
    );
  });

  group('ChatBloc penelusuran LAN', () {
    final lanResolved = <String>[];
    var lanCalls = 0;

    blocTest<ChatBloc, ChatState>(
      'kandidat statis mati → lanDiscoverer dijalankan dan hasilnya diadopsi',
      build: () {
        lanCalls = 0;
        lanResolved.clear();
        return ChatBloc(
          apiClient: _probingClient('http://10.9.23.171:9901', {'192.168.9.50'}),
          agentId: 'agent-1',
          candidateUrls: const [
            'http://10.9.23.171:9901',
            'http://localhost:9901',
            'http://10.0.2.2:9901',
          ],
          probeTimeout: const Duration(seconds: 2),
          clientFactory: ChatBlocProbeHarness.factoryFor({'192.168.9.50'}),
          lanDiscoverer: () async {
            lanCalls++;
            return ['http://192.168.9.50:9901'];
          },
          onApiBaseUrlResolved: lanResolved.add,
        );
      },
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>()
            .having((s) => s.status, 'status', ChatStatus.ready)
            .having((s) => s.agent?.name, 'nama agent', 'Asisten'),
        isA<ChatState>().having((s) => s.isCheckingSetup, 'cek setup', isTrue),
        isA<ChatState>()
            .having((s) => s.profileName, 'profile', 'test')
            .having((s) => s.needsSetup, 'needsSetup', isFalse),
      ],
      verify: (bloc) {
        expect(lanCalls, 1);
        expect(bloc.apiClient.baseUrl, 'http://192.168.9.50:9901');
        expect(lanResolved, ['http://192.168.9.50:9901']);
      },
    );

    blocTest<ChatBloc, ChatState>(
      'kandidat statis menemukan server → penelusuran LAN tidak dijalankan',
      build: () {
        lanCalls = 0;
        return ChatBloc(
          apiClient: _probingClient('http://10.9.23.171:9901', {'localhost'}),
          agentId: 'agent-1',
          candidateUrls: const [
            'http://10.9.23.171:9901',
            'http://localhost:9901',
          ],
          probeTimeout: const Duration(seconds: 2),
          clientFactory: ChatBlocProbeHarness.factoryFor({'localhost'}),
          lanDiscoverer: () async {
            lanCalls++;
            return ['http://jangan-dipakai:9901'];
          },
        );
      },
      act: (bloc) => bloc.add(const ChatOpened()),
      verify: (bloc) {
        expect(lanCalls, 0);
        expect(bloc.apiClient.baseUrl, 'http://localhost:9901');
      },
    );

    blocTest<ChatBloc, ChatState>(
      'lanDiscoverer melempar galat → tetap gagal rapi dengan petunjuk host',
      build: () {
        lanCalls = 0;
        return ChatBloc(
          apiClient: _probingClient('http://localhost:9901', {}),
          agentId: 'agent-1',
          candidateUrls: const ['http://localhost:9901'],
          probeTimeout: const Duration(seconds: 2),
          clientFactory: ChatBlocProbeHarness.factoryFor({}),
          lanDiscoverer: () async {
            lanCalls++;
            throw Exception('jaringan filmis');
          },
        );
      },
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>()
            .having((s) => s.status, 'status', ChatStatus.failed)
            .having((s) => s.errorMessage, 'ada petunjuk', contains('adb reverse')),
      ],
      verify: (_) => expect(lanCalls, 1),
    );
  });
}
