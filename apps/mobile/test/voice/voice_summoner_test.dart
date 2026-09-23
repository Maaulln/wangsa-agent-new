import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/voice/voice_input.dart';
import 'package:wangsa_mobile/voice/voice_summoner.dart';

class _FakeDisplay implements SummonDisplay {
  int showCalls = 0;
  int hideCalls = 0;
  String? lastWakeWord;
  bool permissionsResult = true;

  @override
  Future<bool> ensurePermissions() async => permissionsResult;

  @override
  Future<void> showSummon(String wakeWord) async {
    showCalls++;
    lastWakeWord = wakeWord;
  }

  @override
  Future<void> hideSummon() async => hideCalls++;
}

class _FakeVoiceInput implements VoiceInput {
  final _controller = StreamController<VoiceEvent>.broadcast();

  void emit(VoiceEvent event) => _controller.add(event);

  @override
  Stream<VoiceEvent> get events => _controller.stream;

  @override
  VoiceStatus get status => VoiceStatus.idle;

  @override
  Future<void> startWakeWordWatch() async {}

  @override
  Future<void> stopWakeWordWatch() async {}

  @override
  Future<void> startListening() async {}

  @override
  Future<void> speakReply(String text) async {}

  @override
  Future<void> readAloud(String text) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  bool get isSpeaking => false;

  @override
  Future<void> endConversation() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tidak menampilkan apa pun saat foreground', () async {
    final display = _FakeDisplay();
    final voice = _FakeVoiceInput();
    final summoner = VoiceSummoner(display: display, wakeWord: 'Hallo Wangsa');
    summoner.setForegroundForTest(true);
    summoner.attach(voice);

    voice.emit(const WakeWordDetected());
    await Future<void>.delayed(Duration.zero);

    expect(display.showCalls, 0);

    await summoner.dispose();
    await voice.dispose();
  });

  test('menampilkan panggilan saat detect dalam background', () async {
    final display = _FakeDisplay();
    final voice = _FakeVoiceInput();
    final summoner = VoiceSummoner(display: display, wakeWord: 'Hallo Wangsa');
    summoner.attach(voice);
    summoner.setForegroundForTest(false);

    voice.emit(const WakeWordDetected());
    await Future<void>.delayed(Duration.zero);

    expect(display.showCalls, 1);
    expect(display.lastWakeWord, 'Hallo Wangsa');

    await summoner.dispose();
    await voice.dispose();
  });

  test('menutup panggilan saat ucapan selesai', () async {
    final display = _FakeDisplay();
    final voice = _FakeVoiceInput();
    final summoner = VoiceSummoner(display: display, wakeWord: 'Hallo Wangsa');
    summoner.attach(voice);
    summoner.setForegroundForTest(false);

    voice.emit(const WakeWordDetected());
    await Future<void>.delayed(Duration.zero);
    voice.emit(const FinalTranscript('halo'));
    await Future<void>.delayed(Duration.zero);

    expect(display.showCalls, 1);
    expect(display.hideCalls, 1);

    await summoner.dispose();
    await voice.dispose();
  });

  test('kembali ke foreground dengan bel tertunda memulai dikte', () async {
    final display = _FakeDisplay();
    final voice = _FakeVoiceInput();
    var visibilityChanges = <bool>[];
    var acceptedCalls = 0;
    final summoner = VoiceSummoner(
      display: display,
      wakeWord: 'Hallo Wangsa',
      onVisibilityChanged: visibilityChanges.add,
      onSummonAccepted: () async => acceptedCalls++,
    );
    summoner.attach(voice);
    summoner.setForegroundForTest(false);

    voice.emit(const WakeWordDetected());
    await Future<void>.delayed(Duration.zero);
    expect(display.showCalls, 1);

    // Mensimulasikan pengguna mengetuk panggilan (kembali ke foreground).
    summoner.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(visibilityChanges, [false]);
    expect(acceptedCalls, 1);
    expect(display.hideCalls, 1);

    await summoner.dispose();
    await voice.dispose();
  });

  test('kembali ke foreground tanpa bel tidak memulai dikte', () async {
    final display = _FakeDisplay();
    final voice = _FakeVoiceInput();
    var acceptedCalls = 0;
    final summoner = VoiceSummoner(
      display: display,
      wakeWord: 'Hallo Wangsa',
      onSummonAccepted: () async => acceptedCalls++,
    );
    summoner.attach(voice);
    summoner.setForegroundForTest(false);
    summoner.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(acceptedCalls, 0);

    await summoner.dispose();
    await voice.dispose();
  });
}
