import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/api/models.dart';
import 'package:wangsa_mobile/api/wangsa_api_client.dart';
import 'package:wangsa_mobile/chat/bloc/chat_bloc.dart';
import 'package:wangsa_mobile/profile/user_profile_controller.dart';

WangsaApiClient clientYangMenjawab(
  http.Response Function(http.Request) jawab, {
  bool meConfigured = true,
}) => WangsaApiClient(
  baseUrl: 'https://api.wangsa.test',
  httpClient: MockClient((request) async {
    final path = request.url.path;
    // Onboarding gate (SetupStatusRequested) memanggil endpoint ini
    // setiap ChatOpened — jawab bawaan agar test lama yang hanya peduli
    // agent/pesan tidak perlu diubah satu per satu.
    if (path.endsWith('/api/v1/auth/me')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {'profile': 'test', 'configured': meConfigured},
        }),
        200,
      );
    }
    if (path.endsWith('/models') && request.method == 'GET') {
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {
            'provider': '',
            'current': '',
            'models': [],
            'providers': [],
          },
        }),
        200,
      );
    }
    if (path.endsWith('/api/v1/auth/providers') && request.method == 'GET') {
      return http.Response(
        jsonEncode({
          'success': true,
          'data': {'providers': []},
        }),
        200,
      );
    }
    return jawab(request);
  }),
);

http.Response agentOk() => http.Response(
  jsonEncode({
    'success': true,
    'data': {
      'id': 'agent-1',
      'name': 'Asisten Akademik',
      'purpose': 'Membantu tugas',
    },
  }),
  200,
);

http.Response balasanOk(String teks) => http.Response(
  jsonEncode({
    'success': true,
    'data': {'response': teks},
  }),
  200,
);

http.Response tidakDitemukan() => http.Response(
  jsonEncode({
    'success': false,
    'error': {'code': 'NOT_FOUND', 'message': 'Not found.'},
  }),
  404,
);

void main() {
  group('ChatBloc saat dibuka', () {
    blocTest<ChatBloc, ChatState>(
      'memuat Agent lalu siap dipakai',
      build: () => ChatBloc(
        apiClient: clientYangMenjawab((_) => agentOk()),
        agentId: 'agent-1',
      ),
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>()
            .having((s) => s.status, 'status', ChatStatus.ready)
            .having((s) => s.agent?.name, 'nama agent', 'Asisten Akademik'),
        isA<ChatState>().having((s) => s.isCheckingSetup, 'cek setup', isTrue),
        isA<ChatState>()
            .having((s) => s.profileName, 'profile', 'test')
            .having((s) => s.needsSetup, 'needsSetup', isFalse),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'token ditolak menandai authInvalid agar layar menawarkan keluar',
      build: () => ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/api/v1/auth/me')) {
              return http.Response(
                jsonEncode({
                  'success': false,
                  'error': {
                    'code': 'UNAUTHORIZED',
                    'message': 'Token tidak valid.',
                  },
                }),
                401,
              );
            }
            return agentOk();
          }),
        ),
        agentId: 'agent-1',
      ),
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.ready),
        isA<ChatState>().having((s) => s.isCheckingSetup, 'cek setup', isTrue),
        isA<ChatState>().having((s) => s.authInvalid, 'authInvalid', isTrue),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'Agent yang tidak ada memberi satu keadaan tidak ditemukan',
      build: () => ChatBloc(
        apiClient: clientYangMenjawab((_) => tidakDitemukan()),
        agentId: 'agent-1',
      ),
      act: (bloc) => bloc.add(const ChatOpened()),
      expect: () => [
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.loading),
        isA<ChatState>().having((s) => s.status, 'status', ChatStatus.notFound),
      ],
    );
  });

  group('ChatBloc saat mengirim pesan', () {
    test('pilihan capability dikirim pada pesan pertama sesi baru', () async {
      late Map<String, dynamic> sent;
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((request) {
          if (request.method == 'POST') {
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return balasanOk('hasil pencarian');
          }
          return agentOk();
        }),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ToolsetsSelected(['web']));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const MessageSubmitted('Cari berita terbaru'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent['toolsets'], ['web']);
      expect(bloc.state.selectedToolsets, ['web']);
    });

    blocTest<ChatBloc, ChatState>(
      'menambahkan giliran pengguna lalu giliran Agent',
      build: () => ChatBloc(
        apiClient: clientYangMenjawab(
          (request) => request.method == 'POST'
              ? balasanOk('Ada dua tugas.')
              : agentOk(),
        ),
        agentId: 'agent-1',
      ),
      act: (bloc) async {
        bloc.add(const ChatOpened());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const MessageSubmitted('Tugas apa?'));
      },
      skip: 4,
      expect: () => [
        isA<ChatState>()
            .having((s) => s.turns.length, 'jumlah giliran', 1)
            .having((s) => s.turns.last.content, 'isi', 'Tugas apa?')
            .having((s) => s.isSending, 'sedang mengirim', isTrue),
        isA<ChatState>()
            .having((s) => s.turns.length, 'jumlah giliran', 2)
            .having((s) => s.turns.last.role, 'peran', TurnRole.agent)
            .having((s) => s.turns.last.content, 'isi', 'Ada dua tugas.')
            .having((s) => s.isSending, 'sedang mengirim', isFalse),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'kegagalan kirim menampilkan galat dan tidak menambah giliran Agent',
      build: () => ChatBloc(
        apiClient: clientYangMenjawab(
          (request) => request.method == 'POST'
              ? http.Response(
                  jsonEncode({
                    'success': false,
                    'error': {
                      'code': 'RUNTIME_ERROR',
                      'message': 'Agent sedang bermasalah.',
                    },
                  }),
                  502,
                )
              : agentOk(),
        ),
        agentId: 'agent-1',
      ),
      act: (bloc) async {
        bloc.add(const ChatOpened());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const MessageSubmitted('Halo'));
      },
      skip: 5,
      expect: () => [
        isA<ChatState>()
            .having((s) => s.turns.length, 'jumlah giliran', 1)
            .having((s) => s.errorMessage, 'galat', 'Agent sedang bermasalah.')
            .having((s) => s.isSending, 'sedang mengirim', isFalse),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'MessageCancelled menghentikan tanpa menunggu, dan balasan yang '
      'telat datang tidak menimpa state lagi',
      build: () => ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/api/v1/auth/me')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {'profile': 'test', 'configured': true},
                }),
                200,
              );
            }
            if (path.endsWith('/models') && request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'provider': '',
                    'current': '',
                    'models': [],
                    'providers': [],
                  },
                }),
                200,
              );
            }
            if (request.method != 'POST') return agentOk();
            // Simulasi balasan server yang lambat — cukup lambat supaya
            // MessageCancelled pasti sempat diproses lebih dulu.
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return balasanOk('Telat.');
          }),
        ),
        agentId: 'agent-1',
      ),
      act: (bloc) async {
        bloc.add(const ChatOpened());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const MessageSubmitted('Halo'));
        bloc.add(const MessageCancelled());
      },
      skip: 4,
      wait: const Duration(milliseconds: 50),
      expect: () => [
        isA<ChatState>()
            .having((s) => s.turns.length, 'jumlah giliran', 1)
            .having((s) => s.isSending, 'sedang mengirim', isTrue),
        isA<ChatState>()
            .having((s) => s.turns.length, 'jumlah giliran', 1)
            .having((s) => s.isSending, 'sedang mengirim', isFalse),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'pesan kosong diabaikan',
      build: () => ChatBloc(
        apiClient: clientYangMenjawab((_) => agentOk()),
        agentId: 'agent-1',
      ),
      act: (bloc) async {
        bloc.add(const ChatOpened());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const MessageSubmitted('   '));
      },
      skip: 4,
      expect: () => <ChatState>[],
    );

    test('mengirim model efektif (pilihan pengguna) ke setiap pesan', () async {
      late Map<String, dynamic> terkirim;
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((request) {
          if (request.method == 'POST') {
            terkirim = jsonDecode(request.body) as Map<String, dynamic>;
            return balasanOk('ok');
          }
          return agentOk();
        }),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ChatOpened());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ModelSelected('model-b'));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const MessageSubmitted('Halo'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terkirim['model'], 'model-b');
      expect(terkirim.containsKey('llm'), isFalse);
      expect(terkirim['toolsets'], isEmpty);
    });

    test('profil kosong tidak mengirim userName/userBio sama sekali', () async {
      late Map<String, dynamic> terkirim;
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((request) {
          if (request.method == 'POST') {
            terkirim = jsonDecode(request.body) as Map<String, dynamic>;
            return balasanOk('ok');
          }
          return agentOk();
        }),
        agentId: 'agent-1',
        userProfile: UserProfileController.fake(),
      );
      addTearDown(bloc.close);

      bloc.add(const MessageSubmitted('Halo'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terkirim.containsKey('userName'), isFalse);
      expect(terkirim.containsKey('userBio'), isFalse);
    });

    test('profil terisi mengirim userName/userBio apa adanya', () async {
      late Map<String, dynamic> terkirim;
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((request) {
          if (request.method == 'POST') {
            terkirim = jsonDecode(request.body) as Map<String, dynamic>;
            return balasanOk('ok');
          }
          return agentOk();
        }),
        agentId: 'agent-1',
        userProfile: UserProfileController.fake(
          initial: const UserProfile(
            name: 'Doni',
            preferences: 'santai, bahasa Indonesia',
          ),
        ),
      );
      addTearDown(bloc.close);

      bloc.add(const MessageSubmitted('Halo'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terkirim['userName'], 'Doni');
      expect(terkirim['userBio'], 'santai, bahasa Indonesia');
    });

    test(
      'nama panggilan kosong memakai nama akun; yang terisi menang',
      () async {
        Future<Map<String, dynamic>> kirim(UserProfile profil) async {
          late Map<String, dynamic> terkirim;
          final bloc = ChatBloc(
            apiClient: clientYangMenjawab((request) {
              if (request.method == 'POST') {
                terkirim = jsonDecode(request.body) as Map<String, dynamic>;
                return balasanOk('ok');
              }
              return agentOk();
            }),
            agentId: 'agent-1',
            userProfile: UserProfileController.fake(initial: profil),
            userNameFallback: 'maulchat2',
          );
          addTearDown(bloc.close);
          bloc.add(const MessageSubmitted('Halo'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return terkirim;
        }

        expect((await kirim(const UserProfile()))['userName'], 'maulchat2');
        expect(
          (await kirim(const UserProfile(name: 'Doni')))['userName'],
          'Doni',
        );
      },
    );

    test('tanpa pilihan, model aktif server yang dikirim', () async {
      late Map<String, dynamic> terkirim;
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/api/v1/auth/me')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {'profile': 'test', 'configured': true},
                }),
                200,
              );
            }
            if (request.method == 'POST') {
              terkirim = jsonDecode(request.body) as Map<String, dynamic>;
              return balasanOk('ok');
            }
            if (request.url.path.endsWith('/models')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'provider': 'prov',
                    'current': 'model-a',
                    'models': ['model-a', 'model-b'],
                  },
                }),
                200,
              );
            }
            return agentOk();
          }),
        ),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ChatOpened());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bloc.state.models, ['model-a', 'model-b']);
      expect(bloc.state.effectiveModel, 'model-a');

      bloc.add(const MessageSubmitted('Halo'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terkirim['model'], 'model-a');
    });

    test('ModelSelected(null) kembali ke bawaan server', () async {
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((_) => agentOk()),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ModelSelected('model-b'));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.effectiveModel, 'model-b');

      bloc.add(const ModelSelected(null));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.selectedModel, isNull);
    });

    test('menghapus model pilihan yang sudah ditarik provider', () async {
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/api/v1/auth/me')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {'profile': 'test', 'configured': true},
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/models')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'provider': 'opencode-free',
                    'current': 'nemotron-3-ultra-free',
                    'models': ['nemotron-3-ultra-free'],
                    'providers': [
                      {
                        'id': 'opencode-free',
                        'name': 'OpenCode Free',
                        'models': ['nemotron-3-ultra-free'],
                      },
                    ],
                  },
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/api/v1/auth/budget')) {
              return http.Response(
                jsonEncode({'success': true, 'data': {}}),
                200,
              );
            }
            if (request.url.path.endsWith('/api/v1/auth/providers')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {'providers': []},
                }),
                200,
              );
            }
            return agentOk();
          }),
        ),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ChatOpened());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bloc.add(const ModelSelected('hy3-free', provider: 'opencode-free'));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.effectiveModel, 'hy3-free');

      bloc.add(const ModelsRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.selectedModel, isNull);
      expect(bloc.state.effectiveModel, 'nemotron-3-ultra-free');
    });

    test('pesan gambar tanpa teks tetap terkirim dengan lampiran', () async {
      late Map<String, dynamic> terkirim;
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((request) {
          if (request.method == 'POST') {
            terkirim = jsonDecode(request.body) as Map<String, dynamic>;
            return balasanOk('ok');
          }
          return agentOk();
        }),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ChatOpened());
      await Future<void>.delayed(Duration.zero);
      bloc.add(
        MessageSubmitted(
          '   ',
          images: const [
            ChatImage(bytes: [1, 2, 3]),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(terkirim['images'], hasLength(1));
      expect(bloc.state.turns.first.imageCount, 1);
    });
  });

  group('ChatBloc sesi dan AI metadata', () {
    test(
      'AgentBuildRequested memulai chat baru dengan brief rancangan',
      () async {
        late Map<String, dynamic> sent;
        final bloc = ChatBloc(
          apiClient: clientYangMenjawab((request) {
            if (request.method == 'POST') {
              sent = jsonDecode(request.body) as Map<String, dynamic>;
              return balasanOk('Rancangan agent siap ditinjau.');
            }
            return agentOk();
          }),
          agentId: 'agent-1',
        );
        addTearDown(bloc.close);

        bloc.add(
          const AgentBuildRequested('Nama: Riset. Tujuan: rangkum laporan.'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(sent['message'], contains('Nama: Riset'));
        expect(bloc.state.turns, hasLength(2));
        expect(bloc.state.turns.first.role, TurnRole.user);
        expect(bloc.state.turns.last.content, 'Rancangan agent siap ditinjau.');
      },
    );

    test('memetakan thought dan toolCalls ke Turn Agent', () async {
      final bloc = ChatBloc(
        apiClient: clientYangMenjawab((request) {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'response': 'Hasil kalkulasi 42',
                  'thought': 'Memikirkan rumus...',
                  'toolCalls': [
                    {
                      'tool': 'calculator',
                      'preview': '40 + 2',
                      'status': 'completed',
                    },
                  ],
                  'sessionId': 'sess-123',
                },
              }),
              200,
            );
          }
          return agentOk();
        }),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const ChatOpened());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const MessageSubmitted('Hitung'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.turns, hasLength(2));
      final agentTurn = bloc.state.turns.last;
      expect(agentTurn.thought, 'Memikirkan rumus...');
      expect(agentTurn.toolCalls, hasLength(1));
      expect(agentTurn.toolCalls.first.tool, 'calculator');
      expect(bloc.state.sessionId, 'sess-123');
    });

    test('SessionsRequested memuat daftar sesi ke state', () async {
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/sessions')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'sessions': [
                      {
                        'sessionId': 'sess-1',
                        'title': 'Sesi 1',
                        'lastMessage': 'Halo',
                        'updatedAt': '2025-01-01T00:00:00Z',
                      },
                    ],
                  },
                }),
                200,
              );
            }
            return agentOk();
          }),
        ),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const SessionsRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.sessions, hasLength(1));
      expect(bloc.state.sessions.first.sessionId, 'sess-1');
      expect(bloc.state.sessions.first.title, 'Sesi 1');
    });

    test('SessionDeleted menghapus sesi dari state', () async {
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            if (request.method == 'DELETE') {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {'deleted': true},
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/sessions')) {
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'sessions': [
                      {'sessionId': 'sess-1', 'title': 'Sesi 1'},
                      {'sessionId': 'sess-2', 'title': 'Sesi 2'},
                    ],
                  },
                }),
                200,
              );
            }
            return agentOk();
          }),
        ),
        agentId: 'agent-1',
      );
      addTearDown(bloc.close);

      bloc.add(const SessionsRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bloc.state.sessions, hasLength(2));

      bloc.add(const SessionDeleted('sess-1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bloc.state.sessions, hasLength(1));
      expect(bloc.state.sessions.first.sessionId, 'sess-2');
    });

    test(
      'SessionSelected memulihkan capability yang tersimpan di sesi',
      () async {
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/sessions')) {
                return http.Response(
                  jsonEncode({
                    'success': true,
                    'data': {
                      'sessions': [
                        {
                          'sessionId': 'sess-web',
                          'title': 'Dengan web',
                          'toolsets': ['web'],
                        },
                      ],
                    },
                  }),
                  200,
                );
              }
              if (request.url.path.endsWith('/messages')) {
                return http.Response(
                  jsonEncode({
                    'success': true,
                    'data': {'turns': []},
                  }),
                  200,
                );
              }
              return agentOk();
            }),
          ),
          agentId: 'agent-1',
        );
        addTearDown(bloc.close);

        bloc.add(const SessionsRequested());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bloc.add(const SessionSelected('sess-web'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bloc.state.selectedToolsets, ['web']);
      },
    );

    test(
      'SessionSelected memuat transkrip sesi lampau, bukan mengosongkannya',
      () async {
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/messages') &&
                  request.method == 'GET') {
                return http.Response(
                  jsonEncode({
                    'success': true,
                    'data': {
                      'turns': [
                        {'role': 'user', 'content': 'Halo dari sesi lama'},
                        {'role': 'agent', 'content': 'Halo juga!'},
                      ],
                    },
                  }),
                  200,
                );
              }
              return agentOk();
            }),
          ),
          agentId: 'agent-1',
        );
        addTearDown(bloc.close);

        bloc.add(const SessionSelected('sess-lama'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bloc.state.sessionId, 'sess-lama');
        expect(bloc.state.turns, hasLength(2));
        expect(bloc.state.turns.first.role, TurnRole.user);
        expect(bloc.state.turns.first.content, 'Halo dari sesi lama');
        expect(bloc.state.turns.last.role, TurnRole.agent);
        expect(bloc.state.turns.last.content, 'Halo juga!');
        expect(bloc.state.isLoadingHistory, isFalse);
      },
    );

    test(
      'SessionSelected yang gagal memuat tetap menampilkan galat, bukan diam-diam kosong',
      () async {
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/messages') &&
                  request.method == 'GET') {
                return http.Response(
                  jsonEncode({
                    'success': false,
                    'error': {
                      'code': 'RUNTIME_ERROR',
                      'message': 'Server bermasalah.',
                    },
                  }),
                  500,
                );
              }
              return agentOk();
            }),
          ),
          agentId: 'agent-1',
        );
        addTearDown(bloc.close);

        bloc.add(const SessionSelected('sess-lama'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(bloc.state.sessionId, 'sess-lama');
        expect(bloc.state.turns, isEmpty);
        expect(bloc.state.errorMessage, 'Server bermasalah.');
        expect(bloc.state.isLoadingHistory, isFalse);
      },
    );
  });
}
