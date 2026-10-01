import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wangsa_mobile/api/wangsa_api_client.dart';
import 'package:wangsa_mobile/auth/mobile_auth_controller.dart';
import 'package:wangsa_mobile/chat/bloc/chat_bloc.dart';
import 'package:wangsa_mobile/chat/view/chat_page.dart';
import 'package:wangsa_mobile/chat/view/message_bubble.dart';
import 'package:wangsa_mobile/chat/view/widgets/voice_orb.dart';
import 'package:wangsa_mobile/config/app_config.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';
import 'package:wangsa_mobile/profile/user_profile_controller.dart';
import 'package:wangsa_mobile/theme/theme_controller.dart';
import 'package:wangsa_mobile/theme/wangsa_theme.dart';
import 'package:wangsa_mobile/voice/voice_input.dart';

import '../support/fake_voice_input.dart';

http.Response _agentOk() => http.Response(
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

http.Response _balasanOk(String teks) => http.Response(
  jsonEncode({
    'success': true,
    'data': {'response': teks},
  }),
  200,
);

/// Onboarding gate (SetupStatusRequested) memanggil endpoint ini setiap
/// ChatOpened — jawab bawaan `configured: true` agar test widget yang
/// hanya peduli suara/lampiran/model tidak perlu mock setup satu per satu.
http.Response _meOk() => http.Response(
  jsonEncode({
    'success': true,
    'data': {'profile': 'test', 'configured': true},
  }),
  200,
);

http.Response _providersEmpty() => http.Response(
  jsonEncode({
    'success': true,
    'data': {'providers': []},
  }),
  200,
);

Future<http.Response> Function(http.Request) _withSetup(
  Future<http.Response> Function(http.Request) inner,
) => (request) async {
  final path = request.url.path;
  if (path.endsWith('/api/v1/auth/me')) return _meOk();
  if (path.endsWith('/api/v1/auth/providers') && request.method == 'GET') {
    return _providersEmpty();
  }
  return inner(request);
};

const _config = AppConfig(
  apiBaseUrl: 'https://api.wangsa.test',
  defaultAgentId: 'agent-1',
);

/// [disableAnimations] bawaannya benar: bola gelombang di lapisan suara
/// berputar terus selama status mendengarkan, dan `pumpAndSettle`
/// menunggu sampai animasi berhenti sendiri — tanpa ini, test yang
/// memanggil `pumpAndSettle` menggantung selamanya (lihat AGENTS.md,
/// "Continuous Animations in Widget Tests"). Test yang justru ingin
/// memeriksa perilaku animasinya sendiri boleh mengoper `false`.
Widget _buildApp(
  ChatBloc bloc,
  FakeVoiceInput voiceInput, {
  AppConfig config = _config,
  String? configProblem,
  bool disableAnimations = true,
}) => MediaQuery(
  data: MediaQueryData(disableAnimations: disableAnimations),
  child: MaterialApp(
    theme: WangsaTheme.forBrightness(Brightness.light),
    home: BlocProvider.value(
      value: bloc,
      child: ChatPage(
        config: config,
        configProblem: configProblem,
        voiceInput: voiceInput,
        themeController: ThemeController.withMode(ThemeMode.light),
        llmSettings: LlmSettingsController.fake(),
        userProfile: UserProfileController.fake(),
      ),
    ),
  ),
);

void main() {
  group('ChatPage, chat sebagai rumah tetap', () {
    testWidgets(
      'keadaan kosong tampil begitu Agent siap, tanpa perlu berpindah layar apa pun',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(_withSetup((_) async => _agentOk())),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        expect(find.byType(SvgPicture), findsOneWidget);
        expect(find.text('Mulai percakapan'), findsOneWidget);
        expect(find.text('Tulis pesan untuk Wangsa'), findsOneWidget);
      },
    );

    testWidgets('gelembung pengguna dan Agent berada di sisi yang benar', (
      tester,
    ) async {
      const userTurn = Turn(role: TurnRole.user, content: 'Pesan pengguna');
      const agentTurn = Turn(role: TurnRole.agent, content: 'Balasan agent');

      await tester.pumpWidget(
        MaterialApp(
          theme: WangsaTheme.forBrightness(Brightness.light),
          home: const Scaffold(
            body: Column(
              children: [
                MessageBubble(turn: userTurn),
                MessageBubble(turn: agentTurn),
              ],
            ),
          ),
        ),
      );

      final userAlign = tester.widget<Align>(
        find.ancestor(
          of: find.text('Pesan pengguna'),
          matching: find.byType(Align),
        ),
      );
      final agentAlign = tester.widget<Align>(
        find.ancestor(
          of: find.text('Balasan agent'),
          matching: find.byType(Align),
        ),
      );

      expect(userAlign.alignment, Alignment.centerRight);
      expect(agentAlign.alignment, Alignment.centerLeft);
    });
  });

  group('ChatPage, sesi auth', () {
    testWidgets(
      'token ditolak menampilkan banner keluar dan menekan tombol menghapus sesi',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          MobileAuthController.tokenKey: 'tok-lama',
          MobileAuthController.profileKey: 'budi',
        });
        final auth = MobileAuthController(token: 'tok-lama', profile: 'budi');
        addTearDown(auth.dispose);
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient((request) async {
              final path = request.url.path;
              if (path.endsWith('/api/v1/auth/me')) {
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
              if (path.endsWith('/api/v1/auth/token') &&
                  request.method == 'DELETE') {
                return http.Response(
                  jsonEncode({
                    'success': true,
                    'data': {'revoked': true},
                  }),
                  200,
                );
              }
              return _agentOk();
            }),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MaterialApp(
              theme: WangsaTheme.forBrightness(Brightness.light),
              home: BlocProvider.value(
                value: bloc,
                child: ChatPage(
                  config: _config,
                  voiceInput: voiceInput,
                  themeController: ThemeController.withMode(ThemeMode.light),
                  llmSettings: LlmSettingsController.fake(),
                  userProfile: UserProfileController.fake(),
                  auth: auth,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Sesi berakhir.'), findsOneWidget);
        await tester.tap(find.text('Keluar'));
        await tester.pumpAndSettle();

        expect(auth.isSignedIn, isFalse);
      },
    );
  });

  group('ChatPage, lapisan suara', () {
    testWidgets(
      'tidak tampil sampai mikrofon ditekan atau kata pemicu terdengar',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(_withSetup((_) async => _agentOk())),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        expect(find.byType(VoiceOrb), findsNothing);
      },
    );

    testWidgets(
      'menekan tombol mikrofon membuka lapisan dan memanggil startListening',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(_withSetup((_) async => _agentOk())),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Bicara'));
        await tester.pump();

        expect(voiceInput.startListeningCalls, 1);
        expect(find.byType(VoiceOrb), findsOneWidget);
        expect(find.text('Mendengarkan...'), findsOneWidget);
      },
    );

    testWidgets(
      'kata pemicu terdengar membuka lapisan tanpa harus menekan apa pun',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(_withSetup((_) async => _agentOk())),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        voiceInput.emit(
          const WakeWordDetected(),
          status: VoiceStatus.listening,
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(VoiceOrb), findsOneWidget);
        expect(find.text('Mendengarkan...'), findsOneWidget);
      },
    );

    testWidgets('mengetuk area gelap membatalkan dan memanggil stop', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(_withSetup((_) async => _agentOk())),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildApp(bloc, voiceInput));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Bicara'));
      await tester.pump();
      expect(find.byType(VoiceOrb), findsOneWidget);

      // Ketuk pojok layar, di luar kartu lapisan suara.
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();

      expect(find.byType(VoiceOrb), findsNothing);
      expect(voiceInput.stopCalls, 1);
    });

    testWidgets('PartialTranscript tampil di dalam lapisan suara', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(_withSetup((_) async => _agentOk())),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildApp(bloc, voiceInput));
      await tester.pumpAndSettle();

      voiceInput.emit(
        const PartialTranscript('halo wa'),
        status: VoiceStatus.listening,
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('halo wa'), findsOneWidget);
    });

    testWidgets(
      'FinalTranscript menutup lapisan dan mengirim MessageSubmitted',
      (tester) async {
        final voiceInput = FakeVoiceInput()..followUpListening = false;
        var pesanTerkirim = false;
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(
              _withSetup((request) async {
                if (request.method == 'POST') {
                  pesanTerkirim = true;
                  return _balasanOk('Halo juga');
                }
                return _agentOk();
              }),
            ),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        voiceInput.emit(
          const FinalTranscript('halo wangsa'),
          status: VoiceStatus.processing,
        );
        await tester.pump();
        await tester.pump();

        // Lapisan suara sudah tertutup begitu ucapan selesai dikirim; tanpa
        // mikrofon lanjutan ia tidak dibuka lagi oleh balasan.
        expect(find.byType(VoiceOrb), findsNothing);

        await tester.pumpAndSettle();

        expect(pesanTerkirim, isTrue);
        expect(find.text('halo wangsa'), findsOneWidget);
        expect(find.text('Halo juga'), findsOneWidget);
      },
    );

    testWidgets(
      'balasan Agent atas ucapan dibacakan lalu lapisan suara dibuka lagi untuk lanjutan',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(
              _withSetup(
                (request) async => request.method == 'POST'
                    ? _balasanOk('Halo juga')
                    : _agentOk(),
              ),
            ),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        voiceInput.emit(
          const FinalTranscript('halo wangsa'),
          status: VoiceStatus.processing,
        );
        // Bukan pumpAndSettle: lapisan yang terbuka lagi berisi bola yang
        // beranimasi terus (lihat AGENTS.md).
        await tester.pump();
        await tester.pump();

        expect(voiceInput.spokenReplies, ['Halo juga']);
        // Mikrofon lanjutan sudah menyala, jadi pengguna harus melihatnya.
        expect(find.byType(VoiceOrb), findsOneWidget);
        expect(voiceInput.endConversationCalls, 0);
      },
    );

    testWidgets(
      'balasan yang gagal mengakhiri percakapan suara dan tidak membacakan apa pun',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(
              _withSetup(
                (request) async => request.method == 'POST'
                    ? http.Response('galat', 500)
                    : _agentOk(),
              ),
            ),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        voiceInput.emit(
          const FinalTranscript('halo wangsa'),
          status: VoiceStatus.processing,
        );
        await tester.pumpAndSettle();

        expect(voiceInput.spokenReplies, isEmpty);
        expect(voiceInput.endConversationCalls, 1);
        expect(find.byType(VoiceOrb), findsNothing);
      },
    );

    testWidgets(
      'VoiceFailure membuka lapisan dan menampilkan galat tanpa mengirim pesan',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        var permintaanPost = 0;
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient((request) async {
              if (request.method == 'POST') permintaanPost++;
              return _agentOk();
            }),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        voiceInput.emit(const VoiceFailure('mikrofon tidak tersedia'));
        await tester.pump();
        await tester.pump();

        expect(find.text('mikrofon tidak tersedia'), findsOneWidget);
        expect(find.text('Tutup'), findsOneWidget);
        expect(permintaanPost, 0);

        await tester.tap(find.text('Tutup'));
        await tester.pump();

        expect(find.byType(VoiceOrb), findsNothing);
      },
    );

    // `VoiceOrb` sejak memakai paket `siri_orb` mengurus animasi
    // putarannya sendiri secara internal (`AnimationController` privat di
    // dalam widget paket itu) — tidak lagi menerima `_waveController` dari
    // luar, jadi tidak bisa lagi diperiksa lewat properti publik seperti
    // sebelumnya.
    //
    // Sempat dicoba memindahkan pemeriksaan ini ke `ThinkingIndicator`
    // (pemakai `_waveController` yang tersisa) — tapi `ThinkingIndicator`
    // tidak bisa dibangun sama sekali di widget test tanpa mesin
    // sungguhan: `_Avatar`-nya memanggil `VideoPlayerController.initialize()`
    // di `initState`, yang melempar `UnimplementedError` ("init() has not
    // been implemented") karena `video_player` tidak punya platform
    // channel di lingkungan test. Memalsukan seluruh `VideoPlayerPlatform`
    // (banyak method abstrak) hanya untuk satu pemeriksaan reduce-motion
    // ini tidak sepadan — jadi cakupan test untuk kepatuhan
    // `_waveController` pada `disableAnimations` sengaja dilepas di sini,
    // BUKAN lupa. Perilakunya sendiri (`didChangeDependencies` di
    // chat_page.dart) tidak berubah dan tetap sederhana.
  });

  group('ChatPage, keadaan galat', () {
    testWidgets('keadaan galat menampilkan ikon dan teks', (tester) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'success': false,
                'error': {
                  'code': 'SERVER_ERROR',
                  'message': 'Terjadi kesalahan server.',
                },
              }),
              500,
            ),
          ),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildApp(bloc, voiceInput));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.error_outline), findsWidgets);
      expect(find.text('Gagal terhubung'), findsOneWidget);
      expect(find.text('Terjadi kesalahan server.'), findsOneWidget);
    });
  });

  group('ChatPage dan layar galat dengan konfigurasi cadangan', () {
    testWidgets(
      'keadaan failed dengan configProblem menampilkan alasan dan alamat API',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'http://10.0.2.2:3001',
            httpClient: MockClient(
              (_) async => http.Response('Koneksi ditolak', 500),
            ),
          ),
          agentId: 'belum-diatur',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        const fallback = AppConfig(
          apiBaseUrl: 'http://10.0.2.2:3001',
          defaultAgentId: 'belum-diatur',
        );

        await tester.pumpWidget(
          _buildApp(
            bloc,
            voiceInput,
            config: fallback,
            configProblem: 'Berkas konfigurasi tidak bisa dijangkau.',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Gagal terhubung'), findsOneWidget);
        expect(find.text('Memakai konfigurasi cadangan'), findsOneWidget);
        expect(
          find.text('Berkas konfigurasi tidak bisa dijangkau.'),
          findsOneWidget,
        );
        expect(find.text('http://10.0.2.2:3001'), findsOneWidget);
        final apiText = tester.widget<Text>(find.text('http://10.0.2.2:3001'));
        expect(apiText.style?.fontFamily, 'monospace');
        expect(
          find.text('Buka layar Pengaturan untuk memeriksa konfigurasi.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'keadaan failed tanpa configProblem tidak menampilkan blok konfigurasi cadangan',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'https://api.wangsa.test',
            httpClient: MockClient(
              (_) async => http.Response('Server error', 500),
            ),
          ),
          agentId: 'agent-1',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        await tester.pumpWidget(_buildApp(bloc, voiceInput));
        await tester.pumpAndSettle();

        expect(find.text('Gagal terhubung'), findsOneWidget);
        expect(find.text('Memakai konfigurasi cadangan'), findsNothing);
      },
    );

    testWidgets(
      'keadaan notFound dengan configProblem menampilkan blok konfigurasi cadangan',
      (tester) async {
        final voiceInput = FakeVoiceInput();
        final bloc = ChatBloc(
          apiClient: WangsaApiClient(
            baseUrl: 'http://10.0.2.2:3001',
            httpClient: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'success': false,
                  'error': {'code': 'NOT_FOUND', 'message': 'Agent not found'},
                }),
                404,
              ),
            ),
          ),
          agentId: 'belum-diatur',
        )..add(const ChatOpened());
        addTearDown(bloc.close);

        const fallback = AppConfig(
          apiBaseUrl: 'http://10.0.2.2:3001',
          defaultAgentId: 'belum-diatur',
        );

        await tester.pumpWidget(
          _buildApp(
            bloc,
            voiceInput,
            config: fallback,
            configProblem: 'Berkas konfigurasi tidak bisa dijangkau.',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Agent tidak tersedia'), findsOneWidget);
        expect(find.text('Memakai konfigurasi cadangan'), findsOneWidget);
        expect(
          find.text('Berkas konfigurasi tidak bisa dijangkau.'),
          findsOneWidget,
        );
        expect(find.text('http://10.0.2.2:3001'), findsOneWidget);
        final apiText = tester.widget<Text>(find.text('http://10.0.2.2:3001'));
        expect(apiText.style?.fontFamily, 'monospace');
        expect(
          find.text('Buka layar Pengaturan untuk memeriksa konfigurasi.'),
          findsOneWidget,
        );
      },
    );
  });

  group('ChatPage, pemilih model dan lampiran', () {
    WangsaApiClient clientDenganModel({
      List<String> models = const ['model-a', 'model-b'],
      String current = 'model-a',
      void Function(http.Request)? onPost,
    }) => WangsaApiClient(
      baseUrl: 'https://api.wangsa.test',
      httpClient: MockClient(
        _withSetup((request) async {
          if (request.method == 'POST') {
            onPost?.call(request);
            return _balasanOk('Siap');
          }
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'provider': 'prov',
                  'current': current,
                  'models': models,
                },
              }),
              200,
            );
          }
          return _agentOk();
        }),
      ),
    );

    Widget buildAppDenganPemilih(ChatBloc bloc, FakeVoiceInput voiceInput) =>
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: WangsaTheme.forBrightness(Brightness.light),
            home: BlocProvider.value(
              value: bloc,
              child: ChatPage(
                config: _config,
                voiceInput: voiceInput,
                themeController: ThemeController.withMode(ThemeMode.light),
                llmSettings: LlmSettingsController.fake(),
                userProfile: UserProfileController.fake(),
              ),
            ),
          ),
        );

    testWidgets('pil menampilkan model aktif dan memilih dari lembar', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(apiClient: clientDenganModel(), agentId: 'agent-1')
        ..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(buildAppDenganPemilih(bloc, voiceInput));
      await tester.pumpAndSettle();

      // Pemilihan model kini dipindah ke drawer (bukan pil di composer).
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();

      // Baris model di drawer menampilkan model aktif server, bukan nama agent.
      expect(find.text('model-a'), findsOneWidget);

      await tester.tap(find.text('Model & Provider'));
      await tester.pumpAndSettle();

      expect(find.text('model-b'), findsOneWidget);
      await tester.tap(find.text('model-b'));
      await tester.pumpAndSettle();

      expect(bloc.state.selectedModel, 'model-b');
    });

    testWidgets('pilihan model tetap terbuka saat daftar belum tersedia', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(_withSetup((_) async => _agentOk())),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(buildAppDenganPemilih(bloc, voiceInput));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Asisten Akademik'), findsOneWidget);
      await tester.tap(find.text('Model & Provider'));
      await tester.pumpAndSettle();

      expect(find.text('Pilih Provider & Model'), findsOneWidget);
      expect(find.text('Coba lagi'), findsOneWidget);
    });

    testWidgets('lampiran tampil sebagai pratinjau lalu terkirim bersama pesan', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      http.Request? terkirim;
      final bloc = ChatBloc(
        apiClient: clientDenganModel(onPost: (r) => terkirim = r),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      final gambar = PendingImage(
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        ),
        mimeType: 'image/png',
        filename: 't.png',
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: WangsaTheme.forBrightness(Brightness.light),
            home: BlocProvider.value(
              value: bloc,
              child: ChatPage(
                config: _config,
                voiceInput: voiceInput,
                themeController: ThemeController.withMode(ThemeMode.light),
                llmSettings: LlmSettingsController.fake(),
                userProfile: UserProfileController.fake(),
                pickImage: () async => gambar,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Lampiran'));
      await tester.pump();
      await tester.pump();

      // Pratinjau muncul dengan tombol buang.
      expect(find.byType(Image), findsOneWidget);

      await tester.tap(find.byTooltip('Kirim'));
      await tester.pumpAndSettle();

      expect(terkirim, isNotNull);
      final badan = jsonDecode(terkirim!.body) as Map<String, dynamic>;
      expect(badan['images'], hasLength(1));
      expect(
        bloc.state.turns.firstWhere((t) => t.role == TurnRole.user).imageCount,
        1,
      );
      // Pratinjau dibersihkan sesudah terkirim.
      expect(find.byType(Image), findsNothing);
    });
  });

  group('ChatPage, laci', () {
    testWidgets('membuka ruang kerja Bangun Agent dari sidebar', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(_withSetup((_) async => _agentOk())),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildApp(bloc, voiceInput));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Percakapan baru'), findsOneWidget);
      expect(find.text('Bangun Agent'), findsOneWidget);
      await tester.tap(find.text('Bangun Agent'));
      await tester.pumpAndSettle();

      expect(find.text('Apa tujuan utamanya?'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Susun rancangan di chat'), findsOneWidget);
      expect(
        find.textContaining('belum tersedia lewat API mobile'),
        findsOneWidget,
      );
    });

    testWidgets('bilah bawah tetap: ketuk Profil membuka ProfilePage', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(_withSetup((_) async => _agentOk())),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildApp(bloc, voiceInput));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      await tester.tap(find.byIcon(Icons.person_outline));
      await tester.pumpAndSettle();

      expect(find.text('Wangsa belum punya sistem akun'), findsOneWidget);
      expect(find.text('Asisten Akademik'), findsOneWidget);
    });

    testWidgets('bilah bawah tetap: ketuk ikon gear membuka SettingsPage', (
      tester,
    ) async {
      final voiceInput = FakeVoiceInput();
      final bloc = ChatBloc(
        apiClient: WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient(_withSetup((_) async => _agentOk())),
        ),
        agentId: 'agent-1',
      )..add(const ChatOpened());
      addTearDown(bloc.close);

      await tester.pumpWidget(_buildApp(bloc, voiceInput));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Id agent'), findsOneWidget);
      expect(find.text('agent-1'), findsOneWidget);
    });
  });
}
