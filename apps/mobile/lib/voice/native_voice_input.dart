import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'foreground_service.dart';
import 'speech_engine.dart';
import 'tts_engine.dart';
import 'voice_input.dart';
import 'wake_word_engine.dart';

/// Implementasi nyata pertama dari kontrak `VoiceInput` (lihat
/// voice_input.dart untuk aturan lengkapnya).
///
/// Mengomposisi tiga mesin yang sepenuhnya independen dan tidak saling
/// kenal satu sama lain — [WakeWordEngine] (Porcupine), [SpeechEngine]
/// (`speech_to_text`), dan [ForegroundServiceController]
/// (`flutter_foreground_task`) — dan kelas inilah, bukan salah satu dari
/// ketiganya, yang menegakkan aturan "hanya satu pemegang mikrofon" yang
/// didokumentasikan di kontrak.
class NativeVoiceInput implements VoiceInput {
  final String? _accessKey;
  final String _keywordAssetPath;
  final String _modelAssetPath;
  final WakeWordEngineFactory _createWakeWordEngine;
  final SpeechEngine _speechEngine;
  final TtsEngine _tts;
  final ForegroundServiceController _foregroundService;

  final _controller = StreamController<VoiceEvent>.broadcast();
  VoiceStatus _status = VoiceStatus.off;
  WakeWordEngine? _wakeEngine;
  bool _disposed = false;

  /// [accessKey] null berarti wake word tidak dikonfigurasi untuk
  /// pemasangan ini (lihat `AppConfig.wakeWordAccessKey`) —
  /// [startWakeWordWatch] menjadi no-op permanen dan status tetap
  /// [VoiceStatus.off] sampai [dispose]. Dikte lewat tombol mikrofon
  /// ([startListening]) tetap berfungsi tanpa AccessKey, karena jalur itu
  /// tidak memakai Porcupine sama sekali.
  final bool _enabled;

  /// Bila true, deteksi kata pemicu hanya memancarkan [WakeWordDetected]
  /// tanpa otomatis memulai dikte. Dipakai saat aplikasi di background
  /// (lihat `VoiceSummoner`): `speech_to_text` tidak bisa diandalkan tanpa
  /// activity di depan, dan pengguna belum tentu siap bicara — dikte
  /// dimulai nanti saat pengguna mengetuk panggilan (aplikasi kembali
  /// ke depan). Pengawasan kata pemicu sendiri tetap berjalan dan tetap
  /// memegang mikrofon.
  bool deferAutoListen = false;

  bool _isSpeakingManual = false;

  NativeVoiceInput({
    String? accessKey,
    String keywordAssetPath = 'assets/voice/keywords.txt',
    String modelAssetPath =
        'assets/voice/encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    WakeWordEngineFactory createWakeWordEngine = createSherpaOnnxEngine,
    SpeechEngine? speechEngine,
    TtsEngine? ttsEngine,
    ForegroundServiceController foregroundService =
        const FlutterForegroundServiceController(),
    bool enabled = true,
  }) : _accessKey = accessKey,
       _keywordAssetPath = keywordAssetPath,
       _modelAssetPath = modelAssetPath,
       _createWakeWordEngine = createWakeWordEngine,
       _speechEngine = speechEngine ?? DeviceSpeechEngine(),
       _tts = ttsEngine ?? DeviceTtsEngine(),
       _foregroundService = foregroundService,
       _enabled = enabled;

  bool get _wakeWordConfigured {
    // Mesin on-device (zipformer, openWakeWord) tidak memakai AccessKey;
    // hanya Porcupine yang butuh, dan test memakai lawan palsu.
    if (_createWakeWordEngine == createSherpaOnnxEngine ||
        _createWakeWordEngine == createOpenWakeWordEngine) {
      return _enabled;
    }
    return _accessKey != null && _accessKey.isNotEmpty;
  }

  @override
  Stream<VoiceEvent> get events => _controller.stream;

  @override
  VoiceStatus get status => _status;

  @override
  bool get wakeWordAvailable => _wakeWordConfigured;

  @override
  bool get wakeWordEnabled => _wakeWordEnabled;

  @override
  bool get isSpeaking => _isSpeakingManual;

  /// Pembuatan mesin kata pemicu yang sedang berjalan, atau null. Membuat
  /// mesin butuh waktu (memuat model ONNX, sekitar satu detik), dan selama
  /// itu `_wakeEngine` masih null. Tanpa penanda ini, dua panggilan
  /// [startWakeWordWatch] yang berdekatan (mis. re-arm otomatis dan tombol
  /// batal) sama-sama lolos pengecekan, membuat dua mesin, dan mesin
  /// pertama kehilangan referensinya tanpa pernah dihentikan — terus
  /// memegang mikrofon.
  Future<void>? _startingWakeWord;
  bool _wakeWordEnabled = false;

  @override
  Future<void> startWakeWordWatch() async {
    if (_disposed) return;
    // Panggilan lain sedang membuatnya: ikut menunggu, jangan membuat lagi.
    final inFlight = _startingWakeWord;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    // Sudah menyala: tidak ada yang perlu dilakukan.
    if (_wakeEngine != null) {
      debugPrint(
        '[NativeVoiceInput] startWakeWordWatch(): engine sudah aktif.',
      );
      return;
    }
    if (!_wakeWordConfigured) {
      debugPrint(
        '[NativeVoiceInput] startWakeWordWatch(): wake word TIDAK terkonfigurasi untuk instance ini.',
      );
      _wakeWordEnabled = false;
      _status = VoiceStatus.off;
      return;
    }

    _wakeWordEnabled = true;
    final starting = _buildAndStartWakeWordEngine();
    _startingWakeWord = starting;
    try {
      await starting;
    } finally {
      if (identical(_startingWakeWord, starting)) _startingWakeWord = null;
    }
  }

  /// Tidak pernah melempar: kegagalan dilaporkan sebagai [VoiceFailure].
  Future<void> _buildAndStartWakeWordEngine() async {
    try {
      debugPrint(
        '[NativeVoiceInput] Memulai layanan latar depan dan membuat engine...',
      );
      await _foregroundService.start();

      _wakeEngine = await _createWakeWordEngine(
        accessKey: _accessKey ?? '',
        keywordAssetPath: _keywordAssetPath,
        modelAssetPath: _modelAssetPath,
        onDetected: () {
          debugPrint(
            '[NativeVoiceInput] WakeWordDetected dipicu! Memulai startListening()...',
          );
          _controller.add(const WakeWordDetected());
          // Background (deferAutoListen): panggilan ala Siri yang tampil,
          // dikte menyusul saat pengguna mengetuknya (lihat VoiceSummoner).
          if (!deferAutoListen) unawaited(startListening());
        },
        onError: (message) {
          debugPrint('[NativeVoiceInput] WakeWord onError: $message');
          _controller.add(VoiceFailure('Wake word gagal: $message'));
        },
      );
      debugPrint(
        '[NativeVoiceInput] Engine berhasil dibuat, memulai watch (start)...',
      );
      await _wakeEngine!.start();
      _status = VoiceStatus.idle;
      _controller.add(const WakeWordStatusChanged(true));
      debugPrint(
        '[NativeVoiceInput] Status kini VoiceStatus.idle. Siaga mendengarkan.',
      );
    } catch (e, stack) {
      debugPrint('[NativeVoiceInput] Gagal menyalakan kata pemicu: $e\n$stack');
      _wakeEngine = null;
      _wakeWordEnabled = false;
      _status = VoiceStatus.off;
      try {
        await _foregroundService.stop();
      } catch (stopError) {
        debugPrint(
          '[NativeVoiceInput] Gagal menghentikan layanan setelah start gagal: $stopError',
        );
      }
      _controller.add(const WakeWordStatusChanged(false));
      final message = e.toString().toLowerCase().contains('izin mikrofon')
          ? 'Wangsa perlu izin mikrofon untuk mendengarkan kata pemicu. Aktifkan izin itu, lalu coba lagi.'
          : 'Wangsa belum bisa mengaktifkan kata pemicu. Coba lagi; jika masih gagal, periksa izin mikrofon.';
      _controller.add(VoiceFailure(message));
    }
  }

  @override
  Future<void> stopWakeWordWatch() async {
    _wakeWordEnabled = false;
    await _stopWakeWordEngine();
    _controller.add(const WakeWordStatusChanged(false));
  }

  /// Melepas engine/mikrofon tanpa mengubah preferensi pengguna. Dipakai
  /// ketika dictation mengambil mikrofon; wakeword akan dilanjutkan sesudahnya.
  Future<void> _stopWakeWordEngine() async {
    // Mesin yang masih dibuat harus ditunggu dulu; kalau tidak `_wakeEngine`
    // masih null, tidak ada yang dihentikan, lalu mesinnya lolos dan terus
    // menyala.
    final starting = _startingWakeWord;
    if (starting != null) await starting;

    final wakeEngine = _wakeEngine;
    _wakeEngine = null;
    if (wakeEngine != null) {
      await wakeEngine.stop();
      await wakeEngine.delete();
      await _foregroundService.stop();
    }
    if (_status == VoiceStatus.idle) _status = VoiceStatus.off;
  }

  /// True sejak ucapan akhir yang berisi (pengguna sudah bicara dan
  /// balasan Agent ditunggu) sampai percakapan suara berakhir. Selama itu
  /// mesin kata pemicu sengaja dibiarkan mati: mikrofon dipakai bergantian
  /// oleh dikte dan lanjutan, dan suara Agent yang dibacakan tidak boleh
  /// terdengar oleh pengawas kata pemicu.
  bool _conversationActive = false;

  /// Menomori setiap [speakReply], dan dinaikkan oleh apa pun yang
  /// mengambil alih (ketuk mikrofon, [stop], [endConversation]) supaya
  /// [speakReply] yang sedang menunggu suaranya habis tahu ia sudah
  /// dipotong dan tidak membuka dikte sekali lagi.
  int _speakToken = 0;

  @override
  Future<void> startListening() async {
    if (_disposed) return;

    debugPrint('[NativeVoiceInput] startListening() dipanggil.');
    // Mengetuk mikrofon saat Agent sedang bicara memotong suaranya.
    _speakToken++;
    await _tts.stop();

    // Aturan mikrofon eksklusif (lihat voice_input.dart): lepaskan engine
    // sebelum dikte mengambil mikrofon. Preferensi tetap aktif agar listener
    // kembali otomatis begitu giliran suara selesai.
    if (_wakeEngine != null || _startingWakeWord != null) {
      await _stopWakeWordEngine();
    }

    _status = VoiceStatus.listening;
    await _speechEngine.listen(
      onPartial: (text) {
        debugPrint('[NativeVoiceInput] onPartial: "$text"');
        _controller.add(PartialTranscript(text));
      },
      onFinal: (text) {
        debugPrint('[NativeVoiceInput] onFinal: "$text"');
        _status = VoiceStatus.processing;
        _controller.add(FinalTranscript(text));
        if (text.trim().isEmpty) {
          unawaited(_finishConversation());
        } else {
          // Layar mengirim ucapan ini ke Agent; percakapan berlanjut lewat
          // speakReply / endConversation, bukan lewat kata pemicu.
          _conversationActive = true;
        }
      },
      onError: (message) {
        debugPrint('[NativeVoiceInput] speechEngine onError: $message');
        // Diam bukan kegagalan: pengguna memanggil lalu tidak bicara, atau
        // tidak menjawab setelah Agent bicara. Layar cukup menutup lapisan
        // suara, lewat FinalTranscript kosong yang memang sudah ia tangani,
        // bukan menampilkan "Suara tidak tersedia".
        if (message == 'error_no_match' || message == 'error_speech_timeout') {
          _controller.add(const FinalTranscript(''));
        } else {
          _controller.add(VoiceFailure(message));
        }
        unawaited(_finishConversation());
      },
      // Skala mentahnya tidak didokumentasikan resmi oleh speech_to_text
      // untuk Android (lihat komentar `onSoundLevelChange` di paket itu) —
      // dinormalisasi sekasarnya di sini, bukan di layar, supaya layar
      // hanya pernah melihat rentang 0.0-1.0 yang sudah dijanjikan
      // `SoundLevelChanged`.
      onSoundLevel: (level) => _controller.add(
        SoundLevelChanged(((level + 2) / 12).clamp(0.0, 1.0)),
      ),
    );
  }

  @override
  Future<void> speakReply(String text) async {
    if (_disposed || !_conversationActive) return;

    final token = ++_speakToken;
    final spoken = speechText(text);
    if (spoken.isNotEmpty) {
      debugPrint(
        '[NativeVoiceInput] Membacakan balasan (${spoken.length} karakter)...',
      );
      // Mikrofon dibuka SESUDAH suaranya habis, bukan bersamaan.
      await _tts.speak(spoken);
    }

    // Percakapan bisa dihentikan (stop) atau diambil alih ketukan mikrofon
    // selagi Agent bicara.
    if (_disposed || !_conversationActive || token != _speakToken) return;
    debugPrint(
      '[NativeVoiceInput] Selesai membacakan, membuka mikrofon untuk lanjutan.',
    );
    await startListening();
  }

  @override
  Future<void> readAloud(String text) async {
    if (_disposed) return;
    _speakToken++;
    final spoken = speechText(text);
    if (spoken.isEmpty) return;
    _isSpeakingManual = true;
    try {
      await _tts.speak(spoken);
    } finally {
      _isSpeakingManual = false;
    }
  }

  @override
  Future<void> stopSpeaking() async {
    if (_disposed) return;
    _speakToken++;
    _isSpeakingManual = false;
    await _tts.stop();
  }

  @override
  Future<void> endConversation() async {
    if (_disposed || !_conversationActive) return;
    _speakToken++;
    await _tts.stop();
    await _finishConversation();
  }

  bool _resumingWakeWord = false;

  /// Mengakhiri percakapan dan menyalakan kembali pengawasan kata pemicu,
  /// supaya pengguna bisa memanggil lagi tanpa menutup overlay lebih dulu.
  /// Tanpa ini pengawasan hanya menyala kembali lewat [stop], yaitu bila
  /// pengguna membatalkan manual — jadi kata pemicu hanya bisa dipakai
  /// sekali per sesi aplikasi.
  Future<void> _finishConversation() async {
    _conversationActive = false;
    await _resumeWakeWordWatch();
    // Tidak ada yang menyala kembali (pengawasan memang mati sebelum dikte,
    // atau gagal dibuat): jangan biarkan status tersangkut di
    // listening/processing.
    if (_wakeEngine == null && _status != VoiceStatus.off) {
      _status = VoiceStatus.off;
    }
  }

  /// Tidak melakukan apa pun bila pengawasan memang mati sebelum dikte
  /// dimulai (mis. sakelar "Dengar di latar belakang" dimatikan). Aman
  /// dipanggil berulang: galat dan ucapan akhir bisa datang berurutan
  /// dalam satu sesi, dan hanya satu mesin baru yang boleh dibuat.
  Future<void> _resumeWakeWordWatch() async {
    if (_disposed ||
        !_wakeWordEnabled ||
        _resumingWakeWord ||
        _wakeEngine != null) {
      return;
    }
    _resumingWakeWord = true;
    try {
      // Mikrofon harus benar-benar lepas dari mesin dikte sebelum
      // perekam kata pemicu mengambilnya (aturan mikrofon eksklusif).
      await _speechEngine.cancel();
      if (_disposed) return;
      await startWakeWordWatch();
    } finally {
      _resumingWakeWord = false;
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    // Lebih dulu, supaya speakReply yang sedang menunggu TTS tahu
    // percakapan sudah dihentikan dan tidak membuka mikrofon lagi.
    _conversationActive = false;
    _isSpeakingManual = false;
    _speakToken++;
    await _tts.stop();
    await _speechEngine.cancel();
    if (_wakeWordEnabled) {
      _status = VoiceStatus.idle;
      await startWakeWordWatch();
    } else {
      _status = VoiceStatus.off;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _conversationActive = false;
    _isSpeakingManual = false;
    await _tts.stop();
    await stopWakeWordWatch();
    await _speechEngine.cancel();
    await _controller.close();
  }
}
