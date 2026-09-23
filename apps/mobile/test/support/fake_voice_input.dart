import 'dart:async';

import 'package:wangsa_mobile/voice/voice_input.dart';

/// Lawan palsu `VoiceInput` untuk widget test — tidak menyentuh
/// Porcupine, `speech_to_text`, atau `flutter_foreground_task` sama
/// sekali. Setiap panggilan method dicatat lewat penghitung/bendera
/// publik supaya test bisa menegaskan interaksi tanpa mock framework.
class FakeVoiceInput implements VoiceInput {
  final _controller = StreamController<VoiceEvent>.broadcast();

  VoiceStatus _status = VoiceStatus.off;
  int startWakeWordWatchCalls = 0;
  int stopWakeWordWatchCalls = 0;
  int startListeningCalls = 0;
  int stopCalls = 0;
  final List<String> spokenReplies = [];
  final List<String> readAloudTexts = [];
  int stopSpeakingCalls = 0;
  bool _isSpeaking = false;
  int endConversationCalls = 0;
  bool _conversationActive = false;

  /// Bila false, [speakReply] tidak membuka mikrofon lanjutan. Untuk test
  /// yang hanya ingin memeriksa keadaan layar tepat setelah ucapan akhir,
  /// tanpa lapisan suara yang dibuka lagi oleh balasan.
  bool followUpListening = true;
  bool disposed = false;

  @override
  Stream<VoiceEvent> get events => _controller.stream;

  @override
  VoiceStatus get status => _status;

  @override
  bool get isSpeaking => _isSpeaking;

  /// Test memakai ini untuk memicu kejadian seolah-olah datang dari mesin
  /// suara sungguhan, dan boleh menaikkan [status] mengikutinya supaya
  /// layar yang membaca `voiceInput.status` setelah menerima event
  /// melihat nilai yang konsisten.
  void emit(VoiceEvent event, {VoiceStatus? status}) {
    if (status != null) _status = status;
    // Ucapan akhir yang berisi memulai percakapan suara, seperti di mesin nyata.
    if (event is FinalTranscript && event.text.trim().isNotEmpty) _conversationActive = true;
    _controller.add(event);
  }

  @override
  Future<void> startWakeWordWatch() async {
    startWakeWordWatchCalls++;
    _status = VoiceStatus.idle;
  }

  @override
  Future<void> stopWakeWordWatch() async {
    stopWakeWordWatchCalls++;
    if (_status == VoiceStatus.idle) _status = VoiceStatus.off;
  }

  @override
  Future<void> startListening() async {
    startListeningCalls++;
    _status = VoiceStatus.listening;
  }

  /// Meniru mesin nyata: membacakan balasan lalu membuka mikrofon lagi
  /// untuk lanjutan, sehingga status naik ke listening.
  @override
  Future<void> speakReply(String text) async {
    spokenReplies.add(text);
    // Balasan untuk pesan yang diketik tidak dibacakan dan tidak membuka mikrofon.
    if (_conversationActive && followUpListening) _status = VoiceStatus.listening;
  }

  @override
  Future<void> readAloud(String text) async {
    readAloudTexts.add(text);
    _isSpeaking = true;
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakingCalls++;
    _isSpeaking = false;
  }

  @override
  Future<void> endConversation() async {
    endConversationCalls++;
    _conversationActive = false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _isSpeaking = false;
    _status = VoiceStatus.idle;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _isSpeaking = false;
    await _controller.close();
  }
}
