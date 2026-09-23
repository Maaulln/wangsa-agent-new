import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'wake_word_engine.dart';

/// Implementasi [WakeWordEngine] menggunakan `sherpa_onnx`.
///
/// Berjalan sepenuhnya lokal dan offline di perangkat tanpa koneksi internet
/// dan tanpa memerlukan AccessKey atau akun proprietary.
class SherpaOnnxWakeWordEngine implements WakeWordEngine {
  final sherpa.KeywordSpotter _spotter;
  final AudioRecorder _recorder;
  final void Function() _onDetected;
  final void Function(String message)? _onError;

  /// Level audio mentah (RMS, dinormalisasi kasar ke 0.0-1.0) dari chunk PCM
  /// yang sama yang sudah diambil untuk keyword spotting — bukan capture
  /// mikrofon kedua. Sherpa-onnx `KeywordSpotter` sengaja tidak punya API
  /// transkrip parsial seperti pengenal ucapan umum (`getResult` hanya
  /// mengisi `keyword` sekali kata pemicu itu sendiri cocok) — ini satu-satunya
  /// sinyal "mikrofon benar-benar menangkap suara" yang tersedia sebelum
  /// deteksi sungguhan terjadi. Dipakai Lab Uji Wake Word untuk indikator
  /// level, opsional supaya jalur produksi (`NativeVoiceInput`) tidak perlu
  /// peduli soal ini.
  final void Function(double level)? _onAudioLevel;

  sherpa.OnlineStream? _stream;
  StreamSubscription<Uint8List>? _recordSubscription;
  bool _isListening = false;
  bool _isDisposed = false;

  SherpaOnnxWakeWordEngine._({
    required sherpa.KeywordSpotter spotter,
    required AudioRecorder recorder,
    required void Function() onDetected,
    void Function(String message)? onError,
    void Function(double level)? onAudioLevel,
  })  : _spotter = spotter,
        _recorder = recorder,
        _onDetected = onDetected,
        _onError = onError,
        _onAudioLevel = onAudioLevel;

  static bool _bindingsInitialized = false;

  static Future<void> _initBindingsOnce() async {
    if (!_bindingsInitialized) {
      await sherpa.initBindingsAsync();
      _bindingsInitialized = true;
    }
  }

  /// Memastikan berkas aset Flutter disalin ke penyimpanan internal aplikasi
  /// agar dapat diakses oleh library C++ sherpa-onnx melalui jalur berkas nyata.
  static Future<String> _ensureAssetFile(String assetPath) async {
    final docDir = await getApplicationDocumentsDirectory();
    final fileName = p.basename(assetPath);
    final targetDir = Directory(p.join(docDir.path, 'voice_assets'));
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final targetFile = File(p.join(targetDir.path, fileName));
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    // Berkas teks (seperti keywords.txt) selalu diperbarui agar perubahan konfigurasi langsung berlaku.
    if (!await targetFile.exists() ||
        fileName.endsWith('.txt') ||
        await targetFile.length() != bytes.length) {
      await targetFile.writeAsBytes(bytes, flush: true);
    }
    return targetFile.path;
  }

  /// Membuat dan menginisialisasi mesin pengenal kata pemicu Sherpa-ONNX.
  static Future<WakeWordEngine> create({
    String encoderAssetPath = 'assets/voice/encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    String decoderAssetPath = 'assets/voice/decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    String joinerAssetPath = 'assets/voice/joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
    String tokensAssetPath = 'assets/voice/tokens.txt',
    String keywordsAssetPath = 'assets/voice/keywords.txt',
    double threshold = 0.06,
    double score = 3.0,
    required void Function() onDetected,
    required void Function(String message) onError,
    void Function(double level)? onAudioLevel,
  }) async {
    try {
      debugPrint('[SherpaOnnx] Inisialisasi runtime binding...');
      await _initBindingsOnce();

      debugPrint('[SherpaOnnx] Memeriksa berkas model di penyimpanan lokal...');
      final encoderPath = await _ensureAssetFile(encoderAssetPath);
      final decoderPath = await _ensureAssetFile(decoderAssetPath);
      final joinerPath = await _ensureAssetFile(joinerAssetPath);
      final tokensPath = await _ensureAssetFile(tokensAssetPath);
      final keywordsPath = await _ensureAssetFile(keywordsAssetPath);

      final config = sherpa.KeywordSpotterConfig(
        feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: encoderPath,
            decoder: decoderPath,
            joiner: joinerPath,
          ),
          tokens: tokensPath,
          numThreads: 1,
          provider: 'cpu',
        ),
        keywordsFile: keywordsPath,
        keywordsThreshold: threshold,
        keywordsScore: score,
      );

      final spotter = sherpa.KeywordSpotter(config);
      final recorder = AudioRecorder();
      debugPrint('[SherpaOnnx] KeywordSpotter berhasil dibuat (threshold=$threshold, score=$score).');

      return SherpaOnnxWakeWordEngine._(
        spotter: spotter,
        recorder: recorder,
        onDetected: onDetected,
        onError: onError,
        onAudioLevel: onAudioLevel,
      );
    } catch (e, stack) {
      debugPrint('[SherpaOnnx] Gagal membuat KeywordSpotter: $e\n$stack');
      onError(e.toString());
      rethrow;
    }
  }

  @override
  Future<void> start() async {
    if (_isListening || _isDisposed) return;

    debugPrint('[SherpaOnnx] Memeriksa izin mikrofon...');
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      debugPrint('[SherpaOnnx] Izin mikrofon BELUM diberikan!');
      _onError?.call('Izin mikrofon belum diberikan');
      return;
    }

    debugPrint('[SherpaOnnx] Membuka audio stream PCM16 16kHz mono...');
    _stream = _spotter.createStream();
    final audioStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    _isListening = true;
    debugPrint('[SherpaOnnx] Audio stream aktif. Siaga mendengarkan "Hallo Wangsa"...');
    _recordSubscription = audioStream.listen(
      _handleAudioChunk,
      onError: (err) {
        debugPrint('[SherpaOnnx] Error pada audio stream: $err');
        _onError?.call('Kesalahan perekaman mikrofon: $err');
      },
    );
  }

  void _handleAudioChunk(Uint8List chunk) {
    final stream = _stream;
    if (stream == null || !_isListening || _isDisposed) return;

    try {
      final samples = _convertBytesToFloat32(chunk);
      _onAudioLevel?.call(_rmsLevel(samples));
      stream.acceptWaveform(samples: samples, sampleRate: 16000);

      while (_spotter.isReady(stream)) {
        _spotter.decode(stream);
        final result = _spotter.getResult(stream);
        if (result.keyword.isNotEmpty) {
          debugPrint('[SherpaOnnx] >>> KATA PEMICU TERDETEKSI: "${result.keyword}" <<<');
          _spotter.reset(stream);
          _onDetected();
          break;
        }
      }
    } catch (e, stack) {
      debugPrint('[SherpaOnnx] Kesalahan decoding chunk audio: $e\n$stack');
      _onError?.call('Kesalahan decoding keyword: $e');
    }
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

  static Float32List convertBytesToFloat32ForTest(Uint8List bytes) =>
      _convertBytesToFloat32(bytes);

  /// RMS mentah dikalikan faktor tetap lalu dijepit ke 0.0-1.0 — bukan skala
  /// dBFS yang dikalibrasi, sekadar cukup untuk menggerakkan bar level di
  /// Lab secara proporsional terhadap volume suara nyata (ucapan normal
  /// biasanya RMS-nya jauh di bawah 1.0 dalam skala linear ini).
  static double _rmsLevel(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    var sumSquares = 0.0;
    for (final s in samples) {
      sumSquares += s * s;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    return (rms * 6).clamp(0.0, 1.0);
  }

  static double rmsLevelForTest(Float32List samples) => _rmsLevel(samples);

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

    final stream = _stream;
    _stream = null;
    if (stream != null) {
      stream.free();
    }
  }

  @override
  Future<void> delete() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await stop();
    _recorder.dispose();
    _spotter.free();
  }
}

/// Factory function yang kompatibel dengan [WakeWordEngineFactory]
Future<WakeWordEngine> createSherpaOnnxEngine({
  String accessKey = '',
  String keywordAssetPath = 'assets/voice/keywords.txt',
  String modelAssetPath = 'assets/voice/encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
  required void Function() onDetected,
  required void Function(String message) onError,
}) async {
  return SherpaOnnxWakeWordEngine.create(
    keywordsAssetPath: keywordAssetPath,
    encoderAssetPath: modelAssetPath,
    onDetected: onDetected,
    onError: onError,
  );
}
