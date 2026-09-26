/// Adapter tipis di atas `speech_to_text` — satu-satunya berkas yang
/// boleh mengimpor paket itu, alasan yang sama seperti
/// `wake_word_engine.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../api/wangsa_api_client.dart';

/// Kontrak minimal yang dibutuhkan `NativeVoiceInput` dari sebuah mesin
/// dikte. Dideklarasikan eksplisit (bukan memakai `stt.SpeechToText`
/// langsung) supaya lawan palsu di test tidak perlu mewarisi dari kelas
/// milik paket itu.
abstract interface class SpeechEngine {
  /// Meminta izin mikrofon bila belum ada dan menyiapkan mesin native.
  /// Aman dipanggil berkali-kali — implementasi nyata hanya benar-benar
  /// menginisialisasi sekali dan mengembalikan hasil yang sama sesudahnya.
  Future<bool> initialize();

  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
    void Function(double level)? onSoundLevel,
  });

  /// Menghentikan sesi TANPA memproses apa pun yang sempat terdengar.
  /// Dipakai saat pengguna membatalkan lewat `VoiceInput.stop()` — beda
  /// dari akhir ucapan alami, yang justru harus tetap menghasilkan
  /// transkrip akhir lewat `onFinal`.
  Future<void> cancel();
}

class DeviceSpeechEngine implements SpeechEngine {
  final stt.SpeechToText _speech;
  bool _initialized = false;

  /// Diisi ulang setiap [listen] dipanggil, karena `speech_to_text`
  /// hanya mengizinkan satu `onError` terpasang lewat [initialize] —
  /// bukan per sesi dengar seperti `onResult`.
  void Function(String message)? _activeOnError;

  DeviceSpeechEngine({stt.SpeechToText? speech})
    : _speech = speech ?? stt.SpeechToText();

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onStatus: (status) =>
          debugPrint('[DeviceSpeechEngine] onStatus: $status'),
      onError: (SpeechRecognitionError error) {
        debugPrint(
          '[DeviceSpeechEngine] onError: ${error.errorMsg} (permanent=${error.permanent})',
        );
        _activeOnError?.call(error.errorMsg);
      },
    );
    debugPrint('[DeviceSpeechEngine] initialize() result: $_initialized');
    return _initialized;
  }

  @override
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
    void Function(double level)? onSoundLevel,
  }) async {
    _activeOnError = onError;

    final ready = _initialized || await initialize();
    if (!ready) {
      debugPrint(
        '[DeviceSpeechEngine] Speech recognition tidak tersedia/gagal inisialisasi.',
      );
      onError('Pengenalan suara tidak tersedia di perangkat ini.');
      return;
    }

    debugPrint('[DeviceSpeechEngine] Mulai mendengarkan ucapan pengguna...');
    await _speech.listen(
      // ignore: deprecated_member_use
      localeId: 'id_ID',
      onResult: (SpeechRecognitionResult result) {
        debugPrint(
          '[DeviceSpeechEngine] onResult (final=${result.finalResult}): "${result.recognizedWords}"',
        );
        if (result.finalResult) {
          onFinal(result.recognizedWords);
        } else {
          onPartial(result.recognizedWords);
        }
      },
      onSoundLevelChange: onSoundLevel,
    );
  }

  @override
  Future<void> cancel() async {
    debugPrint('[DeviceSpeechEngine] cancel() dipanggil');
    await _speech.cancel();
  }
}

/// Merekam satu ucapan di HP, berhenti setelah jeda singkat, lalu meminta
/// transkrip dari backend Wangsa. Wakeword tetap diproses lokal.
class BackendSpeechEngine implements SpeechEngine {
  final WangsaApiClient _api;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _noSpeechTimer;
  Timer? _maxDurationTimer;
  String? _recordingPath;
  bool _active = false;
  bool _speechDetected = false;
  bool _finishing = false;
  bool _cancelled = false;
  DateTime? _lastVoiceAt;
  void Function(String text)? _onFinal;
  void Function(String message)? _onError;
  void Function(double level)? _onSoundLevel;

  BackendSpeechEngine(this._api);

  @override
  Future<bool> initialize() => _recorder.hasPermission();

  @override
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
    void Function(double level)? onSoundLevel,
  }) async {
    if (_active) return;
    if (!await _recorder.hasPermission()) {
      onError('Izin mikrofon belum diberikan.');
      return;
    }
    final directory = await getTemporaryDirectory();
    _recordingPath = p.join(
      directory.path,
      'wangsa-voice-${DateTime.now().microsecondsSinceEpoch}.m4a',
    );
    _onFinal = onFinal;
    _onError = onError;
    _onSoundLevel = onSoundLevel;
    _speechDetected = false;
    _cancelled = false;
    _lastVoiceAt = null;
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _recordingPath!,
      );
      _active = true;
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 200))
          .listen(_onAmplitude);
      _noSpeechTimer = Timer(const Duration(seconds: 10), () {
        if (!_speechDetected) unawaited(_finish());
      });
      _maxDurationTimer = Timer(const Duration(seconds: 45), _finish);
      debugPrint('[BackendSpeechEngine] Mulai merekam untuk STT backend.');
    } catch (error) {
      _active = false;
      onError('Tidak bisa memulai perekaman: $error');
    }
  }

  void _onAmplitude(Amplitude amplitude) {
    if (!_active) return;
    final db = amplitude.current;
    _onSoundLevel?.call(((db + 60) / 60).clamp(0.0, 1.0).toDouble());
    if (db > -48) {
      _speechDetected = true;
      _lastVoiceAt = DateTime.now();
      _noSpeechTimer?.cancel();
      return;
    }
    final lastVoiceAt = _lastVoiceAt;
    if (_speechDetected &&
        lastVoiceAt != null &&
        DateTime.now().difference(lastVoiceAt) >=
            const Duration(milliseconds: 1400)) {
      unawaited(_finish());
    }
  }

  Future<void> _finish() async {
    if (!_active || _finishing) return;
    _finishing = true;
    _active = false;
    _noSpeechTimer?.cancel();
    _maxDurationTimer?.cancel();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    final path = _recordingPath;
    _recordingPath = null;
    try {
      final outputPath = await _recorder.stop() ?? path;
      if (!_speechDetected || outputPath == null) {
        _onFinal?.call('');
        return;
      }
      final file = File(outputPath);
      if (!await file.exists()) {
        _onError?.call('Rekaman suara tidak ditemukan.');
        return;
      }
      final result = await _api.transcribeAudio(await file.readAsBytes());
      if (_cancelled) return;
      final transcript = result.dataOrNull;
      if (result.isSuccess && transcript != null) {
        _onFinal?.call(transcript);
      } else {
        _onError?.call(result.errorOrNull?.message ?? 'STT Wangsa gagal.');
      }
    } catch (error) {
      _onError?.call('Tidak bisa mengirim rekaman ke STT Wangsa: $error');
    } finally {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      _onFinal = null;
      _onError = null;
      _onSoundLevel = null;
      _finishing = false;
    }
  }

  @override
  Future<void> cancel() async {
    if (_finishing) {
      _cancelled = true;
      return;
    }
    _active = false;
    _noSpeechTimer?.cancel();
    _maxDurationTimer?.cancel();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    final path = _recordingPath;
    _recordingPath = null;
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    _onFinal = null;
    _onError = null;
    _onSoundLevel = null;
  }
}

typedef SpeechEngineFactory = SpeechEngine Function();
