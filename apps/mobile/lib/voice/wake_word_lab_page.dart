import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'voice_input.dart';
import 'wake_word_engine.dart';

/// Mesin yang sedang dipilih di Lab — dua arsitektur yang dibandingkan:
/// zipformer vs openWakeWord dengan classifier custom "Hallo Wangsa"
/// (lihat open_wake_word_engine.dart).
enum _EngineKind { zipformer, openWakeWord }

// TODO(DEMO-20SEP): HAPUS file ini + tile "Lab Uji Wake Word" di
// settings_page.dart sebelum membangun APK demo 20 September 2026.
// Layar ini alat debug sementara untuk verifikasi open wake word
// (sherpa-onnx) di perangkat Android fisik — bukan bagian produk.

/// Layar lab sementara untuk menguji open wake word (sherpa-onnx) secara
/// terisolasi di perangkat Android fisik.
///
/// Sengaja TIDAK lewat [VoiceInput]/`NativeVoiceInput` milik chat: lab ini
/// memegang [WakeWordEngine] sherpa-onnx-nya sendiri supaya hasil uji
/// (init gagal, mic sibuk, tidak terdeteksi) terlihat murni tanpa
/// tercampur foreground service dan `speech_to_text` milik chat.
/// Aturan "satu pemegang mikrofon" (lihat voice_input.dart) ditegakkan
/// dengan menghentikan watch milik chat saat lab dibuka.
class WakeWordLabPage extends StatefulWidget {
  /// Instance voice milik chat — hanya dipakai untuk menghentikan
  /// pengawasan kata pemicu selama lab berjalan, bukan untuk mendeteksi.
  final VoiceInput voiceInput;

  const WakeWordLabPage({super.key, required this.voiceInput});

  @override
  State<WakeWordLabPage> createState() => _WakeWordLabPageState();
}

class _LabAsset {
  final String label;
  final String assetPath;
  bool present = false;
  int bytes = 0;

  _LabAsset(this.label, this.assetPath);
}

class _WakeWordLabPageState extends State<WakeWordLabPage> {
  static const _encoderAsset = 'assets/voice/encoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _decoderAsset = 'assets/voice/decoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _joinerAsset = 'assets/voice/joiner-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _tokensAsset = 'assets/voice/tokens.txt';
  static const _keywordsAsset = 'assets/voice/keywords.txt';

  static const _melAsset = 'assets/voice/openwakeword/melspectrogram.onnx';
  static const _embeddingAsset = 'assets/voice/openwakeword/embedding_model.onnx';
  static const _classifierAsset = 'assets/voice/openwakeword/hallo_wangsa_v1.onnx';

  static const _maxLogLines = 200;

  _EngineKind _engineKind = _EngineKind.zipformer;

  static List<_LabAsset> _assetsForEngine(_EngineKind kind) {
    if (kind == _EngineKind.openWakeWord) {
      return [
        _LabAsset('melspectrogram (.onnx)', _melAsset),
        _LabAsset('embedding (.onnx)', _embeddingAsset),
        _LabAsset('hallo_wangsa classifier (.onnx)', _classifierAsset),
      ];
    }
    return [
      _LabAsset('encoder (.onnx)', _encoderAsset),
      _LabAsset('decoder (.onnx)', _decoderAsset),
      _LabAsset('joiner (.onnx)', _joinerAsset),
      _LabAsset('tokens.txt', _tokensAsset),
      _LabAsset('keywords.txt', _keywordsAsset),
    ];
  }

  late List<_LabAsset> _assets = _assetsForEngine(_engineKind);

  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();

  WakeWordEngine? _engine;
  bool _isListening = false;
  bool _isBusy = false;
  String _status = 'idle';
  String? _lastDetection;
  String? _keywordsContent;
  bool? _hasPermission;

  double _threshold = 0.06;
  double _score = 3.0;

  // openWakeWord: dinaikkan ke 0.9 (produksi) setelah insiden false-positive
  // 22 Sep 2026 — lihat catatan lengkap di open_wake_word_engine.dart
  // `create()`. Masih perlu verifikasi lebih lanjut di sini dengan beberapa
  // percobaan natural + logat sebelum dianggap final.
  double _openWakeWordThreshold = 0.9;

  /// Level audio mentah 0.0-1.0 dari chunk yang sama yang diproses
  /// KeywordSpotter — lihat komentar `_onAudioLevel` di
  /// sherpa_onnx_wake_word_engine.dart untuk kenapa ini (bukan transkrip
  /// teks) satu-satunya sinyal langsung yang bisa ditunjukkan di sini.
  double _audioLevel = 0.0;

  // Protokol banding Q2-C: label sesi aktif + counter deteksi/percobaan.
  String _activeLabel = 'natural';
  int _naturalTrials = 0;
  int _naturalDetections = 0;
  int _usTrials = 0;
  int _usDetections = 0;

  @override
  void initState() {
    super.initState();
    // Bebaskan mikrofon dari watch milik chat sebelum lab memakainya.
    unawaited(_takeOverMicrophone());
    unawaited(_checkAssets());
    unawaited(_checkPermission());
  }

  Future<void> _takeOverMicrophone() async {
    _appendLog('Lab dibuka: menghentikan watch kata pemicu milik chat...');
    try {
      await widget.voiceInput.stopWakeWordWatch();
      _appendLog('Watch chat dihentikan. Mikrofon bebas untuk lab.');
    } catch (e) {
      _appendLog('Catatan: gagal menghentikan watch chat: $e');
    }
  }

  Future<void> _checkAssets() async {
    for (final asset in _assets) {
      try {
        final data = await rootBundle.load(asset.assetPath);
        asset.present = true;
        asset.bytes = data.lengthInBytes;
      } catch (_) {
        asset.present = false;
        asset.bytes = 0;
      }
    }
    if (_engineKind == _EngineKind.zipformer) {
      try {
        final text = await rootBundle.loadString(_keywordsAsset);
        _keywordsContent = text.trim().isEmpty ? '(kosong)' : text.trim();
      } catch (_) {
        _keywordsContent = '(gagal dibaca)';
      }
    } else {
      _keywordsContent = null;
    }
    if (mounted) setState(() {});
    final missing = _assets.where((a) => !a.present).map((a) => a.label).join(', ');
    if (missing.isEmpty) {
      _appendLog('Cek aset: ${_assets.length}/${_assets.length} file model ditemukan di bundle.');
    } else {
      _appendLog('Cek aset GAGAL — hilang: $missing. Lihat docs/wake-word-setup-mobile.md.');
    }
  }

  Future<void> _switchEngine(_EngineKind kind) async {
    if (_engineKind == kind || _isListening || _isBusy) return;
    setState(() {
      _engineKind = kind;
      _assets = _assetsForEngine(kind);
      _status = 'idle';
    });
    _appendLog('Mesin dipilih: ${kind == _EngineKind.zipformer ? 'Zipformer (Hallo Wangsa)' : 'openWakeWord (Hallo Wangsa)'}');
    await _checkAssets();
  }

  Future<void> _checkPermission() async {
    final recorder = AudioRecorder();
    try {
      final granted = await recorder.hasPermission();
      _hasPermission = granted;
      _appendLog('Izin mikrofon: ${granted ? 'diberikan' : 'BELUM diberikan'}');
    } catch (e) {
      _hasPermission = false;
      _appendLog('Cek izin mikrofon gagal: $e');
    } finally {
      recorder.dispose();
    }
    if (mounted) setState(() {});
  }

  void _appendLog(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    _log.add('[$time] $message');
    if (_log.length > _maxLogLines) {
      _log.removeRange(0, _log.length - _maxLogLines);
    }
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _start() async {
    if (_isListening || _isBusy) return;
    setState(() {
      _isBusy = true;
      _status = 'menyiapkan engine...';
    });
    if (_engineKind == _EngineKind.zipformer) {
      _appendLog('Mulai (zipformer): threshold=$_threshold, score=$_score, label=$_activeLabel');
    } else {
      _appendLog('Mulai (openWakeWord): threshold=$_openWakeWordThreshold, label=$_activeLabel');
    }
    WakeWordEngine? created;
    try {
      void onError(String message) {
        _appendLog('Engine error: $message');
        if (mounted) setState(() => _status = 'error');
      }

      void onAudioLevel(double level) {
        if (mounted) setState(() => _audioLevel = level);
      }
      final engine = _engineKind == _EngineKind.zipformer
          ? await SherpaOnnxWakeWordEngine.create(
              encoderAssetPath: _encoderAsset,
              decoderAssetPath: _decoderAsset,
              joinerAssetPath: _joinerAsset,
              tokensAssetPath: _tokensAsset,
              keywordsAssetPath: _keywordsAsset,
              threshold: _threshold,
              score: _score,
              onDetected: _handleDetected,
              onError: onError,
              onAudioLevel: onAudioLevel,
            )
          : await OpenWakeWordEngine.create(
              melspectrogramAssetPath: _melAsset,
              embeddingAssetPath: _embeddingAsset,
              classifierAssetPath: _classifierAsset,
              threshold: _openWakeWordThreshold,
              onDetected: _handleDetected,
              onError: onError,
              onAudioLevel: onAudioLevel,
            );
      created = engine;
      await engine.start();
      _engine = engine;
      created = null;
      _isListening = true;
      _status = 'listening';
      _appendLog('Engine jalan. Ucapkan kata pemicu sekarang.');
    } catch (e) {
      // create() sukses tapi start() gagal (mis. mic sibuk): jangan
      // bocorkan isolate/stream yang sudah dialokasikan.
      final leaked = created;
      created = null;
      if (leaked != null) {
        try {
          await leaked.stop();
          await leaked.delete();
        } catch (_) {}
      }
      _status = 'error';
      _appendLog('GAGAL menyalakan engine: $e');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _handleDetected() {
    final now = DateTime.now().toIso8601String().substring(11, 19);
    _lastDetection = '[$now] label=$_activeLabel';
    if (_activeLabel == 'natural') {
      _naturalDetections++;
    } else {
      _usDetections++;
    }
    _status = 'terdeteksi!';
    _appendLog('>>> TERDETEKSI ($_activeLabel) pada $now <<<');
  }

  Future<void> _stop() async {
    if (!_isListening && _engine == null) return;
    _appendLog('Berhenti: melepas engine + mikrofon...');
    final engine = _engine;
    _engine = null;
    _isListening = false;
    if (engine != null) {
      try {
        await engine.stop();
        await engine.delete();
      } catch (e) {
        _appendLog('Catatan saat melepas engine: $e');
      }
    }
    if (mounted) {
      setState(() {
        _status = 'stopped';
        _audioLevel = 0.0;
      });
    }
  }

  Future<void> _applyAndRestart() async {
    _appendLog('Terapkan & restart: threshold=$_threshold, score=$_score');
    await _stop();
    await _start();
  }

  Future<void> _copyLog() async {
    final params = _engineKind == _EngineKind.zipformer
        ? 'threshold=$_threshold score=$_score'
        : 'threshold=$_openWakeWordThreshold';
    final header =
        'Lab Wake Word — engine=${_engineKind.name} $params '
        'natural=$_naturalDetections/$_naturalTrials us=$_usDetections/$_usTrials\n';
    await Clipboard.setData(ClipboardData(text: header + _log.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Log disalin ke clipboard.')),
      );
    }
  }

  @override
  void dispose() {
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      unawaited(engine.stop().then((_) => engine.delete()));
    }
    _logScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Lab Uji Wake Word')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Alat debug sementara (dihapus sebelum demo 20 Sept). '
              'Watch kata pemicu milik chat dihentikan sementara agar '
              'mikrofon bebas untuk lab ini.',
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('0 · Mesin'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SegmentedButton<_EngineKind>(
                key: const Key('lab-engine-selector'),
                segments: const [
                  ButtonSegment(
                    value: _EngineKind.zipformer,
                    label: Text('Zipformer (Hallo Wangsa)'),
                    icon: Icon(Icons.graphic_eq),
                  ),
                  ButtonSegment(
                    value: _EngineKind.openWakeWord,
                    label: Text('openWakeWord (Hallo Wangsa)'),
                    icon: Icon(Icons.podcasts),
                  ),
                ],
                selected: {_engineKind},
                onSelectionChanged: (_isListening || _isBusy)
                    ? null
                    : (s) => _switchEngine(s.first),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('1 · Aset model (${_assets.length} file)'),
          Card(
            child: Column(
              children: [
                for (final asset in _assets)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      asset.present ? Icons.check_circle : Icons.error,
                      color: asset.present ? Colors.green : scheme.error,
                    ),
                    title: Text(asset.label),
                    subtitle: Text(asset.assetPath),
                    trailing: Text(
                      asset.present ? _formatBytes(asset.bytes) : 'HILANG',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('2 · Kontrol'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Izin mic: ${_hasPermission == null ? '…' : (_hasPermission! ? 'diberikan' : 'BELUM')}',
                        ),
                      ),
                      TextButton(
                        onPressed: _checkPermission,
                        child: const Text('Cek ulang'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_engineKind == _EngineKind.zipformer) ...[
                    Text('Threshold: ${_threshold.toStringAsFixed(2)}'),
                    Slider(
                      key: const Key('lab-threshold-slider'),
                      value: _threshold,
                      min: 0.01,
                      max: 0.30,
                      divisions: 29,
                      label: _threshold.toStringAsFixed(2),
                      onChanged: _isListening
                          ? null
                          : (v) => setState(() => _threshold = v),
                    ),
                    Text('Score: ${_score.toStringAsFixed(1)}'),
                    Slider(
                      key: const Key('lab-score-slider'),
                      value: _score,
                      min: 1.0,
                      max: 5.0,
                      divisions: 40,
                      label: _score.toStringAsFixed(1),
                      onChanged: _isListening
                          ? null
                          : (v) => setState(() => _score = v),
                    ),
                    const SizedBox(height: 4),
                    const Text('keywords.txt (read-only):'),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _keywordsContent ?? '(memuat…)',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ] else ...[
                    Text('Threshold (skor classifier 0–1): ${_openWakeWordThreshold.toStringAsFixed(2)}'),
                    Slider(
                      key: const Key('lab-openwakeword-threshold-slider'),
                      value: _openWakeWordThreshold,
                      min: 0.05,
                      max: 0.95,
                      divisions: 18,
                      label: _openWakeWordThreshold.toStringAsFixed(2),
                      onChanged: _isListening
                          ? null
                          : (v) => setState(() => _openWakeWordThreshold = v),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Kata pemicu "Hallo Wangsa" tertanam di classifier custom '
                      '(hallo_wangsa_v1.onnx) — bukan diambil dari berkas teks seperti zipformer.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('lab-start-button'),
                    onPressed: (_isListening || _isBusy) ? null : _start,
                    child: Text(_isBusy ? 'Menyiapkan…' : 'Mulai mendengarkan'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('lab-stop-button'),
                    onPressed: (!_isListening || _isBusy) ? null : _stop,
                    child: const Text('Berhenti'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('lab-apply-button'),
                    onPressed: _isBusy ? null : _applyAndRestart,
                    child: const Text('Terapkan & Restart engine'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('3 · Hasil (natural vs US)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Status: $_status',
                    key: const Key('lab-status-text'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Level audio mikrofon (langsung). Sherpa-onnx '
                    'KeywordSpotter TIDAK punya transkrip teks seperti '
                    'pengenal ucapan umum — bar ini dari chunk PCM mentah '
                    'yang sama yang diproses, bukti mikrofon benar-benar '
                    'menangkap suara sebelum masuk ke pencocokan kata pemicu.',
                    style: TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      key: const Key('lab-audio-level-meter'),
                      value: _audioLevel,
                      minHeight: 14,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: _audioLevel > 0.05 ? Colors.green : scheme.outline,
                    ),
                  ),
                  if (_lastDetection != null)
                    Text('Terakhir terdeteksi: $_lastDetection'),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'natural',
                        label: Text('Natural'),
                        icon: Icon(Icons.record_voice_over_outlined),
                      ),
                      ButtonSegment(
                        value: 'us',
                        label: Text('Logat US'),
                        icon: Icon(Icons.language_outlined),
                      ),
                    ],
                    selected: {_activeLabel},
                    onSelectionChanged: (s) {
                      setState(() => _activeLabel = s.first);
                      _appendLog('Label sesi aktif: $_activeLabel');
                    },
                  ),
                  const SizedBox(height: 8),
                  _CounterRow(
                    label: 'Natural (Halo Wangsa)',
                    value: '$_naturalDetections/$_naturalTrials',
                    onTrial: () {
                      setState(() => _naturalTrials++);
                      _appendLog('Percobaan natural #$_naturalTrials diucapkan.');
                    },
                  ),
                  _CounterRow(
                    label: 'US (Hello Wangsa)',
                    value: '$_usDetections/$_usTrials',
                    onTrial: () {
                      setState(() => _usTrials++);
                      _appendLog('Percobaan US #$_usTrials diucapkan.');
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('4 · Log'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    key: const Key('lab-log-view'),
                    height: 220,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _log.isEmpty
                        ? const Text('(log kosong)')
                        : ListView.builder(
                            controller: _logScroll,
                            itemCount: _log.length,
                            itemBuilder: (context, i) => Text(
                              _log[i],
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _log.isEmpty
                              ? null
                              : () => setState(_log.clear),
                          child: const Text('Bersihkan'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _log.isEmpty ? null : _copyLog,
                          child: const Text('Salin log'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _CounterRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTrial;

  const _CounterRow({
    required this.label,
    required this.value,
    required this.onTrial,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onTrial,
            child: const Text('+1 percobaan'),
          ),
        ],
      ),
    );
  }
}
