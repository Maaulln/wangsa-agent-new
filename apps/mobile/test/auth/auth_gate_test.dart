import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wangsa_mobile/auth/mobile_auth_controller.dart';
import 'package:wangsa_mobile/auth/view/auth_gate.dart';
import 'package:wangsa_mobile/config/app_config.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';
import 'package:wangsa_mobile/profile/user_profile_controller.dart';
import 'package:wangsa_mobile/theme/theme_controller.dart';
import 'package:wangsa_mobile/theme/wangsa_theme.dart';

import '../support/fake_voice_input.dart';

const _config = AppConfig(apiBaseUrl: 'http://localhost:9901', defaultAgentId: 'agent-1');

http.Response _json(Object body, [int code = 200]) => http.Response(
      jsonEncode(body),
      code,
      headers: {'content-type': 'application/json'},
    );

Widget _buildGate(MobileAuthController auth, http.Client httpClient) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(
        theme: WangsaTheme.forBrightness(Brightness.light),
        home: AuthGate(
          config: _config,
          voiceInput: FakeVoiceInput(),
          themeController: ThemeController.withMode(ThemeMode.light),
          llmSettings: LlmSettingsController.fake(),
          userProfile: UserProfileController.fake(),
          auth: auth,
          httpClient: httpClient,
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AuthGate', () {
    testWidgets('belum login menampilkan layar daftar', (tester) async {
      final auth = MobileAuthController();
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _buildGate(auth, MockClient((_) async => _json({}))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Buat akun baru'), findsOneWidget);
      expect(find.text('Daftar'), findsOneWidget);
    });

    testWidgets('signup memakai URL yang diisi dan chat lanjut ke server itu', (tester) async {
      final auth = MobileAuthController();
      addTearDown(auth.dispose);
      final seenHosts = <String>[];
      String? signupHost;

      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/api/v1/auth/signup')) {
          signupHost = request.url.host;
          return _json({
            'success': true,
            'data': {'profile': 'budi', 'token': 'tok-123', 'configured': false},
          }, 201);
        }
        if (path.endsWith('/api/v1/auth/me')) {
          seenHosts.add(request.url.host);
          return _json({
            'success': true,
            'data': {'profile': 'budi', 'configured': true},
          });
        }
        if (path.endsWith('/api/v1/auth/budget')) {
          return _json({'success': true, 'data': {}});
        }
        return _json({
          'success': true,
          'data': {'id': 'agent-1', 'name': 'Asisten', 'purpose': 'Membantu'},
        });
      });

      await tester.pumpWidget(_buildGate(auth, mock));
      await tester.pumpAndSettle();

      // Ganti URL server + isi username lalu daftar.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), 'http://192.168.1.7:9901');
      await tester.enterText(fields.at(1), 'budi');
      await tester.tap(find.text('Daftar'));
      await tester.pumpAndSettle();

      // Signup terkirim ke host baru, dan sesi chat (getMe) menyusul ke
      // host yang sama — bukan URL bawaan config.
      expect(signupHost, '192.168.1.7');
      expect(auth.isSignedIn, isTrue);
      expect(auth.profile, 'budi');
      expect(seenHosts, isNotEmpty);
      expect(seenHosts.every((h) => h == '192.168.1.7'), isTrue);
      expect(find.text('Mulai percakapan'), findsOneWidget);
    });

    testWidgets('logout kembali ke layar daftar', (tester) async {
      final auth = MobileAuthController(token: 'tok-123', profile: 'budi');
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        _buildGate(
          auth,
          MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/api/v1/auth/me')) {
              return _json({
                'success': true,
                'data': {'profile': 'budi', 'configured': true},
              });
            }
            if (path.endsWith('/api/v1/auth/budget')) {
              return _json({'success': true, 'data': {}});
            }
            return _json({
              'success': true,
              'data': {'id': 'agent-1', 'name': 'Asisten', 'purpose': 'Membantu'},
            });
          }),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mulai percakapan'), findsOneWidget);

      await auth.clear();
      await tester.pumpAndSettle();

      expect(find.text('Buat akun baru'), findsOneWidget);
    });
  });
}
