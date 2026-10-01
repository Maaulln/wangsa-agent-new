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

      expect(find.text('Daftar ke Wangsa'), findsOneWidget);
      expect(find.text('Daftar'), findsOneWidget);
    });

    testWidgets('signup mengirim username+password lalu chat lanjut ke server default', (tester) async {
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

      // Tidak ada lagi field alamat server — cuma username + kata sandi,
      // langsung ke server default config.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), 'budi');
      await tester.enterText(fields.at(1), 'rahasia123');
      await tester.tap(find.text('Daftar'));
      await tester.pumpAndSettle();

      // Signup + sesi chat (getMe) sama-sama ke host default config.
      expect(signupHost, 'localhost');
      expect(auth.isSignedIn, isTrue);
      expect(auth.profile, 'budi');
      expect(seenHosts, isNotEmpty);
      expect(seenHosts.every((h) => h == 'localhost'), isTrue);
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

      expect(find.text('Daftar ke Wangsa'), findsOneWidget);
    });
  });
}
