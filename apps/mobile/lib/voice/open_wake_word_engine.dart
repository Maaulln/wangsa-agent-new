import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:record/record.dart';

import 'wake_word_engine.dart';

/// Implementasi [WakeWordEngine] memakai pipeline openWakeWord
/// (github.com/dscripka/openWakeWord) dijalankan lewat `flutter_onnxruntime` —
/// arsitektur BEDA dari [SherpaOnnxWakeWordEngine]: bukan satu model
/// transducer, tapi 3 graf ONNX independen (melspectrogram -> embedding ->
/// classifier per-kata-pemicu) yang dirangkai manual di kelas ini. Logika
/// windowing/buffering di bawah ini persis meniru
/// packages/speech/src/openwakeword.ts (versi Node yang sudah diverifikasi
/// jalan sungguhan terhadap model ONNX asli — lihat komentar di sana untuk
/// penjelasan tiap konstanta).
///
/// Kata pemicu produksi "Hallo Wangsa" memakai classifier custom
/// `hallo_wangsa_v1.onnx` (hasil training tim, lihat
/// `wake-word-assets/openWakeWord-repo/my_custom_model/`) — menggantikan
/// classifier pretrained "hey jarvis" dari spike evaluasi arsitektur
/// `try-jarvis` (bahasa Inggris, tidak menyelesaikan masalah false-negative
/// logat Indonesia yang didokumentasikan di
/// docs/wake-word-mobile-status-for-irawan-yardan.md). Bobot pretrained
/// openWakeWord (melspectrogram/embedding) berlisensi CC BY-NC-SA-4.0
/// (non-komersial).
///
/// STATUS: RESOLVED & VERIFIED (emulator arm64 + real device boot path).
/// `sherpa_onnx` and `flutter_onnxruntime` originally could not coexist in
/// one APK — both bundle their own `lib/arm64-v8a/libonnxruntime.so` at the
/// identical path, AGP's merge always keeps sherpa_onnx's copy (a local
/// project module) over flutter_onnxruntime's (an external Maven AAR), and
/// — root cause, confirmed via `llvm-readelf`, not guessed — the two are
/// linked against genuinely different upstream ONNX Runtime releases using
/// incompatible ELF symbol versions (sherpa_onnx needs
/// `OrtGetApiBase@VERS_1.28.2`; flutter_onnxruntime's bundled
/// onnxruntime-android 1.23.0 only exports `@@VERS_1.23.0`). No published
/// onnxruntime-android release satisfies both. Fixed in
/// android/app/build.gradle.kts by giving sherpa_onnx's copy of the library
/// a unique SONAME (`libonnxruntime_sherpa.so`) via `patchelf` and
/// re-linking sherpa_onnx's own native libraries against it, entirely
/// within sherpa_onnx's own project-local build output —
/// flutter_onnxruntime's copy is left untouched. See that file's comments
/// for the full mechanism. Verified live: both
/// `SherpaOnnxWakeWordEngine.create()` (zipformer, "Hallo Wangsa") and
/// `OpenWakeWordEngine.create()` (this class, "Hallo Wangsa") initialize and
/// run successfully in the same app.
class OpenWakeWordEngine implements WakeWordEngine {
  static const int _sampleRate = 16000;
  // openWakeWord memproses audio dalam hop tetap 80ms.
  static const int _hopSamples = 1280;
  // Model embedding mengonsumsi window mel yang bergeser sekian frame setiap
  // kali cukup frame baru terkumpul.
  static const int _embeddingWindowFrames = 76;
  static const int _embeddingWindowStep = 8;
  // Classifier menilai kata pemicu dari 16 embedding terakhir (~1.28 detik audio).
  static const int _classifierEmbeddingCount = 16;
  // Kalibrasi yang diterapkan openWakeWord pada output mentah
  // melspectrogram.onnx agar cocok dengan implementasi mel TensorFlow Google
  // yang dipakai saat training.
  static const double _melCalibrationDivisor = 10;
  static const double _melCalibrationOffset = 2;
  // openWakeWord mengharapkan sampel diskalakan ke magnitudo int16, bukan
  // rentang [-1, 1] yang dipakai `record`/sherpa-onnx.
  static const double _int16Scale = 32768;

  final OrtSession _melSession;
  final OrtSession _embeddingSession;
  final OrtSession _classifierSession;
  final AudioRecorder _recorder;
  final double _threshold;
  final void Function() _onDetected;
  final void Function(String message)? _onError;
  final void Function(double level)? _onAudioLevel;

  StreamSubscription<Uint8List>? _recordSubscription;
  bool _isListening = false;
  bool _isDisposed = false;
  bool _fired = false;

  // Anti false-positive hasil diagnosa offline (packages/speech/diag-hallo-wangsa.ts):
  // beberapa skor pertama setelah buffer terisi adalah transien dingin
  // (~0.98 walau inputnya sunyi) lalu stabil ke ~0.0008. Skor-skor itu
  // dibuang, dan deteksi menuntut beberapa skor beruntun di atas ambang
  // supaya satu jendela liar tidak langsung memicu.
  //
  // Dinaikkan dari 2 ke 3 bersamaan dengan threshold 0.9 (lihat komentar
  // `create()` di bawah) — insiden false-positive 22 Sep 2026 tidak pernah
  // punya 2 skor berturut-turut yang sama-sama ≥0.9, apalagi 3.
  static const int _warmupScoresToSkip = 5;
  static const int _requiredStreak = 3;
  int _scoresProduced = 0;
  int _aboveThresholdStreak = 0;

  // RMS mentah (skala [-1,1], BUKAN versi ×6-clamp yang dipakai
  // `_onAudioLevel`/`_rmsLevel` untuk indikator UI) di bawah mana satu hop
  // dianggap hening dan classifier-nya diabaikan — lihat komentar di
  // `_processHop`. Hening digital murni (emulator tanpa mic) punya RMS
  // persis 0.0; ucapan sungguhan, bahkan pelan, jauh di atas ini.
  static const double _minHopRmsForDetection = 0.002;
  double _lastHopRms = 0.0;

  final List<double> _pcmBuffer = [];
  final List<Float32List> _melBuffer = [];
  final List<Float32List> _embeddingBuffer = [];
  int _newMelFramesSinceWindow = 0;

  OpenWakeWordEngine._({
    required OrtSession melSession,
    required OrtSession embeddingSession,
    required OrtSession classifierSession,
    required AudioRecorder recorder,
    required double threshold,
    required void Function() onDetected,
    void Function(String message)? onError,
    void Function(double level)? onAudioLevel,
  }) : _melSession = melSession,
       _embeddingSession = embeddingSession,
       _classifierSession = classifierSession,
       _recorder = recorder,
       _threshold = threshold,
       _onDetected = onDetected,
       _onError = onError,
       _onAudioLevel = onAudioLevel;

  /// Ambang 0.5 dipakai openWakeWord sebagai referensi umum di dokumentasi
  /// mereka, TAPI belum diverifikasi empiris untuk pipeline ini di repo ini
  /// (beda dengan threshold/score zipformer di
  /// sherpa_onnx_wake_word_engine.dart yang sudah diverifikasi).
  ///
  /// Dinaikkan ke 0.9 (dari 0.5) setelah uji perangkat fisik 22 Sep 2026
  /// menangkap false-positive nyata di `adb logcat`: tiga deteksi beruntun
  /// dalam hitungan detik dari suara latar ruangan, dengan skor naik-turun
  /// 0.978 → 0.876 → 0.746 → 0.968 → 0.474 → 0.622 → 0.769 (bukan pola
  /// ucapan "Hallo Wangsa" sungguhan — deteksi asli pada sesi yang sama
  /// selalu 5-7 skor berturut-turut di 0.94-0.999, stabil tinggi tanpa
  /// jeda). 0.9 dipilih karena deteksi asli itu punya batas aman jauh di
  /// atasnya, sedangkan ledakan false-positive itu hanya menyentuh ≥0.9
  /// di satu skor terisolasi (0.978), tidak dua kali berturut-turut —
  /// lihat `_requiredStreak` di bawah untuk kenapa itu penting. Masih
  /// berbasis SATU insiden yang tertangkap, bukan pengujian sistematis —
  /// anggap sebagai perbaikan sementara, bukan nilai final. Verifikasi
  /// lebih lanjut lewat "Lab Uji Wake Word" (settings_page.dart) dengan
  /// beberapa percobaan natural + logat sebelum menganggap ini selesai.
  static Future<WakeWordEngine> create({
    String melspectrogramAssetPath =
        'assets/voice/openwakeword/melspectrogram.onnx',
    String embeddingAssetPath =
        'assets/voice/openwakeword/embedding_model.onnx',
    String classifierAssetPath =
        'assets/voice/openwakeword/hallo_wangsa_v1.onnx',
    double threshold = 0.9,
    required void Function() onDetected,
    required void Function(String message) onError,
    void Function(double level)? onAudioLevel,
  }) async {
    try {
      debugPrint('[OpenWakeWord] Memuat 3 sesi ONNX dari aset Flutter...');
      final ort = OnnxRuntime();
      final melSession = await ort.createSessionFromAsset(
        melspectrogramAssetPath,
      );
      final embeddingSession = await ort.createSessionFromAsset(
        embeddingAssetPath,
      );
      final classifierSession = await ort.createSessionFromAsset(
        classifierAssetPath,
      );
      final recorder = AudioRecorder();
      debugPrint('[OpenWakeWord] Sesi ONNX siap (threshold=$threshold).');

      return OpenWakeWordEngine._(
        melSession: melSession,
        embeddingSession: embeddingSession,
        classifierSession: classifierSession,
        recorder: recorder,
        threshold: threshold,
        onDetected: onDetected,
        onError: onError,
        onAudioLevel: onAudioLevel,
      );
    } catch (e, stack) {
      debugPrint('[OpenWakeWord] Gagal memuat sesi ONNX: $e\n$stack');
      onError(e.toString());
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    if (_isListening || _isDisposed) return;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw StateError('Izin mikrofon belum diberikan');
    }

    final audioStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );

    _isListening = true;
    _fired = false;
    _scoresProduced = 0;
    _aboveThresholdStreak = 0;
    _pcmBuffer.clear();
    _melBuffer.clear();
    _embeddingBuffer.clear();
    _newMelFramesSinceWindow = 0;
    debugPrint(
      '[OpenWakeWord] Audio stream aktif. Siaga mendengarkan "Hallo Wangsa"...',
    );
    _recordSubscription = audioStream.listen(
      _handleAudioChunk,
      onError: (err) {
        debugPrint('[OpenWakeWord] Error pada audio stream: $err');
        _onError?.call('Kesalahan perekaman mikrofon: $err');
      },
    );
  }

  Future<void> _handleAudioChunk(Uint8List chunk) async {
    if (!_isListening || _isDisposed || _fired) return;
    try {
      final samples = _convertBytesToFloat32(chunk);
      _onAudioLevel?.call(_rmsLevel(samples));

      for (final sample in samples) {
        _pcmBuffer.add(sample.toDouble());
      }

      while (_pcmBuffer.length >= _hopSamples && !_fired) {
        final hop = Float32List.fromList(_pcmBuffer.sublist(0, _hopSamples));
        _pcmBuffer.removeRange(0, _hopSamples);
        await _processHop(hop);
      }
    } catch (e, stack) {
      debugPrint('[OpenWakeWord] Kesalahan pemrosesan chunk audio: $e\n$stack');
      _onError?.call('Kesalahan pemrosesan openWakeWord: $e');
    }
  }

  Future<void> _processHop(Float32List hop) async {
    // Pagar hening: rekam RMS mentah hop TERBARU sebelum dipakai skor di
    // bawah. Perangkat/emulator tanpa mic nyata (mis. emulator Android
    // tanpa host audio passthrough) memberi buffer nol/nyaris-nol terus
    // menerus — diagnosa 22 Sep 2026 menemukan pipeline ini menilai
    // keheningan seperti itu dengan skor TINGGI dan KONSTAN (0.984883...
    // identik di setiap jendela), yang lolos ambang berapa pun karena tidak
    // pernah turun. Kata pemicu tidak boleh menyala dari hening mutlak,
    // jadi classifier diabaikan sepenuhnya kalau hop-nya nyaris tanpa energi
    // — terlepas dari skor yang dihasilkannya.
    _lastHopRms = _rawRms(hop);

    final melRows = await _runMelspectrogram(hop);
    _melBuffer.addAll(melRows);
    _newMelFramesSinceWindow += melRows.length;

    while (_melBuffer.length >= _embeddingWindowFrames &&
        _newMelFramesSinceWindow >= _embeddingWindowStep &&
        !_fired) {
      final window = _melBuffer.sublist(
        _melBuffer.length - _embeddingWindowFrames,
      );
      _embeddingBuffer.add(await _runEmbedding(window));
      _newMelFramesSinceWindow -= _embeddingWindowStep;

      if (_embeddingBuffer.length >= _classifierEmbeddingCount) {
        final classifierWindow = _embeddingBuffer.sublist(
          _embeddingBuffer.length - _classifierEmbeddingCount,
        );
        final score = await _runClassifier(classifierWindow);
        final isSilent = _lastHopRms < _minHopRmsForDetection;
        debugPrint(
          '[OpenWakeWord] skor=${score.toStringAsFixed(6)} rms=${_lastHopRms.toStringAsFixed(6)}'
          '${isSilent ? ' (hening, diabaikan)' : ''}',
        );
        _scoresProduced++;
        if (_scoresProduced <= _warmupScoresToSkip) continue;
        if (score >= _threshold && !isSilent) {
          _aboveThresholdStreak++;
        } else {
          _aboveThresholdStreak = 0;
        }
        if (_aboveThresholdStreak >= _requiredStreak) {
          _fired = true;
          debugPrint(
            '[OpenWakeWord] >>> KATA PEMICU TERDETEKSI (skor=$score) <<<',
          );
          _onDetected();
        }
      }
    }
  }

  Future<List<Float32List>> _runMelspectrogram(Float32List hop) async {
    final scaled = Float32List(hop.length);
    for (var i = 0; i < hop.length; i++) {
      scaled[i] = hop[i] * _int16Scale;
    }

    final inputName = _melSession.inputNames.first;
    final input = await OrtValue.fromList(scaled, [1, scaled.length]);
    try {
      final outputs = await _melSession.run({inputName: input});
      final outTensor = outputs[_melSession.outputNames.first]!;
      try {
        final shape = outTensor.shape;
        final binCount = shape[shape.length - 1];
        final frameCount = shape[shape.length - 2];
        final flat = _flattenNumeric(await outTensor.asList());

        final rows = <Float32List>[];
        for (var f = 0; f < frameCount; f++) {
          final row = Float32List(binCount);
          for (var b = 0; b < binCount; b++) {
            row[b] =
                flat[f * binCount + b] / _melCalibrationDivisor +
                _melCalibrationOffset;
          }
          rows.add(row);
        }
        return rows;
      } finally {
        await outTensor.dispose();
      }
    } finally {
      await input.dispose();
    }
  }

  Future<Float32List> _runEmbedding(List<Float32List> window) async {
    const bins = 32;
    final flatIn = Float32List(_embeddingWindowFrames * bins);
    for (var f = 0; f < _embeddingWindowFrames; f++) {
      flatIn.setRange(f * bins, f * bins + bins, window[f]);
    }

    final inputName = _embeddingSession.inputNames.first;
    final input = await OrtValue.fromList(flatIn, [
      1,
      _embeddingWindowFrames,
      bins,
      1,
    ]);
    try {
      final outputs = await _embeddingSession.run({inputName: input});
      final outTensor = outputs[_embeddingSession.outputNames.first]!;
      try {
        final flat = _flattenNumeric(await outTensor.asList());
        return Float32List.fromList(flat);
      } finally {
        await outTensor.dispose();
      }
    } finally {
      await input.dispose();
    }
  }

  Future<double> _runClassifier(List<Float32List> embeddings) async {
    const embeddingDim = 96;
    final flatIn = Float32List(_classifierEmbeddingCount * embeddingDim);
    for (var e = 0; e < _classifierEmbeddingCount; e++) {
      flatIn.setRange(
        e * embeddingDim,
        e * embeddingDim + embeddingDim,
        embeddings[e],
      );
    }

    final inputName = _classifierSession.inputNames.first;
    final input = await OrtValue.fromList(flatIn, [
      1,
      _classifierEmbeddingCount,
      embeddingDim,
    ]);
    try {
      final outputs = await _classifierSession.run({inputName: input});
      final outTensor = outputs[_classifierSession.outputNames.first]!;
      try {
        final flat = _flattenNumeric(await outTensor.asList());
        return flat.first;
      } finally {
        await outTensor.dispose();
      }
    } finally {
      await input.dispose();
    }
  }

  /// `OrtValue.asList()` tidak terdokumentasi jelas apakah hasilnya rata atau
  /// bersarang mengikuti shape — fungsi ini menangani keduanya sehingga tidak
  /// perlu menebak.
  static List<double> _flattenNumeric(dynamic value) {
    final result = <double>[];
    void walk(dynamic v) {
      if (v is List) {
        for (final item in v) {
          walk(item);
        }
      } else if (v is num) {
        result.add(v.toDouble());
      }
    }

    walk(value);
    return result;
  }

  static Float32List _convertBytesToFloat32(Uint8List bytes) {
    final byteData = ByteData.sublistView(bytes);
    final numSamples = bytes.length ~/ 2;
    final samples = Float32List(numSamples);
    for (var i = 0; i < numSamples; i++) {
      final int16Value = byteData.getInt16(i * 2, Endian.little);
      samples[i] = int16Value / 32768.0;
    }
    return samples;
  }

  /// RMS mentah tanpa penskalaan ×6/clamp — dipakai pagar hening
  /// `_minHopRmsForDetection`, beda dari [_rmsLevel] yang dipakai indikator
  /// level UI.
  static double _rawRms(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    var sumSquares = 0.0;
    for (final s in samples) {
      sumSquares += s * s;
    }
    return math.sqrt(sumSquares / samples.length);
  }

  static double _rmsLevel(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    var sumSquares = 0.0;
    for (final s in samples) {
      sumSquares += s * s;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    return (rms * 6).clamp(0.0, 1.0);
  }

  @override
  Future<void> stop() async {
    if (!_isListening) return;
    _isListening = false;

    await _recordSubscription?.cancel();
    _recordSubscription = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
  }

  @override
  Future<void> delete() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await stop();
    _recorder.dispose();
    await _melSession.close();
    await _embeddingSession.close();
    await _classifierSession.close();
  }
}

/// Factory yang kompatibel dengan [WakeWordEngineFactory], setara
/// `createSherpaOnnxEngine`. Dipakai `NativeVoiceInput` untuk kata pemicu
/// "Hallo Wangsa".
///
/// [accessKey], [keywordAssetPath], dan [modelAssetPath] sengaja
/// DIABAIKAN. Kata pemicunya sudah tertanam di classifier
/// `hallo_wangsa_v1.onnx`, jadi tidak ada berkas kata kunci maupun kunci
/// akses. Kalau [modelAssetPath] diteruskan ke classifier, nilai bawaan
/// `NativeVoiceInput` (path encoder zipformer) akan salah dimuat sebagai
/// classifier. Aset dan ambang 0.5 diambil dari bawaan [OpenWakeWordEngine.create].
Future<WakeWordEngine> createOpenWakeWordEngine({
  String accessKey = '',
  String keywordAssetPath = '',
  String modelAssetPath = '',
  required void Function() onDetected,
  required void Function(String message) onError,
}) {
  return OpenWakeWordEngine.create(onDetected: onDetected, onError: onError);
}
