import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wangsa_mobile/config/app_config.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';
import 'package:wangsa_mobile/profile/user_profile_controller.dart';
import 'package:wangsa_mobile/settings/view/settings_page.dart';
import 'package:wangsa_mobile/theme/theme_controller.dart';

import '../support/fake_voice_input.dart';

Future<Widget> _buildApp(
  AppConfig config,
  FakeVoiceInput voiceInput, {
  UserProfileController? userProfile,
}) async {
  SharedPreferences.setMockInitialValues({});
  final themeController = await ThemeController.load();
  return MaterialApp(
    home: SettingsPage(
      config: config,
      agentId: 'agent-1',
      voiceInput: voiceInput,
      themeController: themeController,
      llmSettings: LlmSettingsController.fake(),
      userProfile: userProfile ?? UserProfileController.fake(),
    ),
  );
}

void main() {
  group('SettingsPage dan sakelar dengar di latar belakang', () {
    testWidgets('engine lokal tetap tersedia tanpa AccessKey', (tester) async {
      const config = AppConfig(
        apiBaseUrl: 'https://api.wangsa.test',
        defaultAgentId: 'agent-1',
      );
      final voiceInput = FakeVoiceInput();

      await tester.pumpWidget(await _buildApp(config, voiceInput));
      await tester.scrollUntilVisible(
        find.byType(Switch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.onChanged, isNotNull);
      expect(switchWidget.value, isFalse);
    });

    // FakeVoiceInput() sengaja mulai dari VoiceStatus.off (lihat
    // fake_voice_input.dart) — ini menguji SettingsPage terisolasi dari
    // bootstrap main.dart, jadi TIDAK perlu diubah untuk "meniru" auto-start
    // default baru di main.dart.
    testWidgets('menyalakan sakelar memanggil startWakeWordWatch', (
      tester,
    ) async {
      const config = AppConfig(
        apiBaseUrl: 'https://api.wangsa.test',
        defaultAgentId: 'agent-1',
        wakeWordAccessKey: 'kunci-uji',
      );
      final voiceInput = FakeVoiceInput();

      await tester.pumpWidget(await _buildApp(config, voiceInput));
      await tester.scrollUntilVisible(
        find.byType(Switch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(voiceInput.startWakeWordWatchCalls, 1);
    });

    testWidgets('mematikan sakelar memanggil stopWakeWordWatch', (
      tester,
    ) async {
      const config = AppConfig(
        apiBaseUrl: 'https://api.wangsa.test',
        defaultAgentId: 'agent-1',
        wakeWordAccessKey: 'kunci-uji',
      );
      final voiceInput = FakeVoiceInput();
      await voiceInput.startWakeWordWatch();

      await tester.pumpWidget(await _buildApp(config, voiceInput));
      await tester.scrollUntilVisible(
        find.byType(Switch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(voiceInput.stopWakeWordWatchCalls, 1);
    });
  });

  group('SettingsPage profil tersimpan otomatis', () {
    const config = AppConfig(
      apiBaseUrl: 'https://api.wangsa.test',
      defaultAgentId: 'agent-1',
    );

    testWidgets('mengetik nama tersimpan setelah jeda, tanpa tombol simpan', (
      tester,
    ) async {
      final profile = UserProfileController.fake();
      await tester.pumpWidget(
        await _buildApp(config, FakeVoiceInput(), userProfile: profile),
      );

      expect(find.text('Simpan profil'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Doni Saputra');
      expect(profile.value.name, isEmpty); // belum lewat jeda

      await tester.pump(const Duration(milliseconds: 700));
      expect(profile.value.name, 'Doni Saputra');
    });

    testWidgets('perubahan yang belum lewat jeda ikut tersimpan saat layar '
        'ditutup', (tester) async {
      final profile = UserProfileController.fake();
      await tester.pumpWidget(
        await _buildApp(config, FakeVoiceInput(), userProfile: profile),
      );

      await tester.enterText(find.byType(TextField).first, 'Sari');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(profile.value.name, 'Sari');
    });
  });
}
