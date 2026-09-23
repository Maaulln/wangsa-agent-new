/// Adapter tipis di atas `porcupine_flutter` — satu-satunya berkas yang
/// boleh mengimpor paket itu. Meniru pola `porcupine-engine.ts` di versi
/// web (`apps/web/src/lib/voice/`): [WakeWordEngineFactory] adalah titik
/// tukar tunggal, supaya `NativeVoiceInput` bisa diuji dengan lawan palsu
/// tanpa pernah menyentuh mikrofon, JNI, atau jaringan sungguhan (Porcupine
/// memvalidasi AccessKey ke server Picovoice sekali di awal).
///
/// `onError` sengaja berupa `String` biasa, bukan tipe galat milik
/// Picovoice — kalau tipe Picovoice bocor ke tanda tangan
/// [WakeWordEngineFactory], setiap berkas yang memakai typedef itu
/// (termasuk `native_voice_input.dart`) ikut terpaksa mengimpor
/// `porcupine_flutter`, meniadakan tujuan mengisolasi paket itu di sini
/// saja.
library;

import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';

export 'open_wake_word_engine.dart';
export 'sherpa_onnx_wake_word_engine.dart';

/// Kontrak minimal yang dibutuhkan `NativeVoiceInput` dari sebuah mesin
/// kata pemicu. `PorcupineManager` memenuhi bentuk ini secara struktural,
/// tapi dideklarasikan eksplisit di sini supaya lawan palsu di test tidak
/// perlu mewarisi dari kelas Porcupine yang sesungguhnya.
abstract interface class WakeWordEngine {
  Future<void> start();
  Future<void> stop();
  Future<void> delete();
}

class _PorcupineWakeWordEngine implements WakeWordEngine {
  final PorcupineManager _manager;

  _PorcupineWakeWordEngine(this._manager);

  @override
  Future<void> start() => _manager.start();

  @override
  Future<void> stop() => _manager.stop();

  @override
  Future<void> delete() => _manager.delete();
}

typedef WakeWordEngineFactory = Future<WakeWordEngine> Function({
  required String accessKey,
  required String keywordAssetPath,
  required String modelAssetPath,
  required void Function() onDetected,
  required void Function(String message) onError,
});

/// Membuat dan memuat (tapi belum menyalakan — panggil `start()` sendiri)
/// mesin Porcupine sungguhan.
///
/// [keywordAssetPath] dan [modelAssetPath] adalah kunci aset Flutter,
/// persis seperti yang didaftarkan di `pubspec.yaml`
/// (`assets/voice/...`), bukan path berkas sistem — `porcupine_flutter`
/// yang mengekstraknya sendiri saat dimuat, aplikasi ini tidak perlu
/// memakai `path_provider`.
Future<WakeWordEngine> createPorcupineEngine({
  required String accessKey,
  required String keywordAssetPath,
  required String modelAssetPath,
  required void Function() onDetected,
  required void Function(String message) onError,
}) async {
  final manager = await PorcupineManager.fromKeywordPaths(
    accessKey,
    [keywordAssetPath],
    (_) => onDetected(),
    modelPath: modelAssetPath,
    // `.toString()`, bukan `.message`: field itu (dan apakah nullable)
    // bisa berbeda antar versi `porcupine_flutter`, sedangkan setiap
    // Exception di Dart menjamin punya `toString()`.
    errorCallback: (PorcupineException error) => onError(error.toString()),
  );
  return _PorcupineWakeWordEngine(manager);
}
