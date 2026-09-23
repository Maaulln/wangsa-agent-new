/// Adapter tipis di atas `speech_to_text` — satu-satunya berkas yang
/// boleh mengimpor paket itu, alasan yang sama seperti
/// `wake_word_engine.dart`.
library;

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

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

  DeviceSpeechEngine({stt.SpeechToText? speech}) : _speech = speech ?? stt.SpeechToText();

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onStatus: (_) {},
      onError: (SpeechRecognitionError error) => _activeOnError?.call(error.errorMsg),
    );
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
      onError('Pengenalan suara tidak tersedia di perangkat ini.');
      return;
    }

    await _speech.listen(
      // ignore: deprecated_member_use
      localeId: 'id_ID',
      onResult: (SpeechRecognitionResult result) {
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
  Future<void> cancel() => _speech.cancel();
}

typedef SpeechEngineFactory = SpeechEngine Function();
