import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wangsa_mobile/config/app_config.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';
import 'package:wangsa_mobile/settings/view/settings_page.dart';
import 'package:wangsa_mobile/theme/theme_controller.dart';

import '../support/fake_voice_input.dart';

Future<Widget> _buildApp(AppConfig config, FakeVoiceInput voiceInput) async {
  SharedPreferences.setMockInitialValues({});
  final themeController = await ThemeController.load();
  return MaterialApp(
    home: SettingsPage(
      config: config,
      agentId: 'agent-1',
      voiceInput: voiceInput,
      themeController: themeController,
      llmSettings: LlmSettingsController.fake(),
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
      await tester.drag(find.byType(ListView), const Offset(0, -800));
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
      await tester.drag(find.byType(ListView), const Offset(0, -800));
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
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(voiceInput.stopWakeWordWatchCalls, 1);
    });
  });
}
