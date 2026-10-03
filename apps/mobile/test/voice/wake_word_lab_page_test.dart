import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/voice/wake_word_lab_page.dart';

import '../support/fake_voice_input.dart';

/// Widget test layar lab uji wake word. Lab tidak menyentuh mikrofon,
/// sherpa-onnx, atau aset sungguhan di sini: [FakeVoiceInput] menggantikan
/// voice milik chat, dan cek aset/izin yang gagal di lingkungan test
/// ditangani halaman sebagai status, bukan lemparan.
void main() {
  /// Halaman lab panjang (4 kartu dalam ListView) — bentangkan viewport
  /// supaya semua tombol terlihat tanpa scroll manual saat di-tap.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('WakeWordLabPage', () {
    testWidgets('membuka lab menghentikan watch milik chat dan tampil idle', (
      tester,
    ) async {
      useTallSurface(tester);
      final voiceInput = FakeVoiceInput();
      addTearDown(voiceInput.dispose);

      await tester.pumpWidget(
        MaterialApp(home: WakeWordLabPage(voiceInput: voiceInput)),
      );
      await tester.pump();
      await tester.pump();

      expect(voiceInput.stopWakeWordWatchCalls, 1);
      expect(find.textContaining('Status: idle'), findsOneWidget);
      expect(find.byKey(const Key('lab-start-button')), findsOneWidget);
      expect(find.byKey(const Key('lab-log-view')), findsOneWidget);
    });

    testWidgets('tombol +1 percobaan menaikkan penyebut counter natural', (
      tester,
    ) async {
      useTallSurface(tester);
      final voiceInput = FakeVoiceInput();
      addTearDown(voiceInput.dispose);

      await tester.pumpWidget(
        MaterialApp(home: WakeWordLabPage(voiceInput: voiceInput)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('0/0'), findsNWidgets(2));

      await tester.tap(
        find.widgetWithText(OutlinedButton, '+1 percobaan').first,
      );
      await tester.pump();

      expect(find.text('0/1'), findsOneWidget);
      expect(find.text('0/0'), findsOneWidget);
    });

    testWidgets('ganti label sesi tercatat di log', (tester) async {
      useTallSurface(tester);
      final voiceInput = FakeVoiceInput();
      addTearDown(voiceInput.dispose);

      await tester.pumpWidget(
        MaterialApp(home: WakeWordLabPage(voiceInput: voiceInput)),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Logat US'));
      await tester.pump();

      expect(find.textContaining('Label sesi aktif: us'), findsOneWidget);
    });
  });
}
