import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/voice/foreground_service.dart';
import 'package:wangsa_mobile/voice/native_voice_input.dart';
import 'package:wangsa_mobile/voice/speech_engine.dart';
import 'package:wangsa_mobile/voice/tts_engine.dart';
import 'package:wangsa_mobile/voice/voice_input.dart';
import 'package:wangsa_mobile/voice/wake_word_engine.dart';

class _FakeWakeWordEngine implements WakeWordEngine {
  bool started = false;
  bool stopped = false;
  bool deleted = false;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> delete() async => deleted = true;
}

/// Menangkap setiap mesin yang dibuat berikut callback `onDetected`/
/// `onError` yang dioper ke masing-masing — supaya test bisa memicunya
/// secara manual, persis peran lawan palsu di test `wake-word.ts` versi
/// web.
class _FakeWakeWordEngineFactory {
  final List<_FakeWakeWordEngine> created = [];
  final List<void Function()> onDetectedCallbacks = [];
  final List<void Function(String)> onErrorCallbacks = [];
  bool throwOnCreate = false;

  Future<WakeWordEngine> call({
    required String accessKey,
    required String keywordAssetPath,
    required String modelAssetPath,
    required void Function() onDetected,
    required void Function(String message) onError,
  }) async {
    if (throwOnCreate) {
      throw Exception('gagal membuat mesin kata pemicu');
    }
    final engine = _FakeWakeWordEngine();
    created.add(engine);
    onDetectedCallbacks.add(onDetected);
    onErrorCallbacks.add(onError);
    return engine;
  }
}

class _FakeSpeechEngine implements SpeechEngine {
  bool initializeResult = true;
  bool canceled = false;
  int listenCalls = 0;
  void Function(String)? onPartial;
  void Function(String)? onFinal;
  void Function(String)? onError;
  void Function(double)? onSoundLevel;

  @override
  Future<bool> initialize() async => initializeResult;

  @override
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
    void Function(double level)? onSoundLevel,
  }) async {
    listenCalls++;
    this.onPartial = onPartial;
    this.onFinal = onFinal;
    this.onError = onError;
    this.onSoundLevel = onSoundLevel;
  }

  @override
  Future<void> cancel() async => canceled = true;
}

/// Menyimpan setiap ucapan dan bisa menahannya (lewat [hold]) sampai test
/// memutuskan TTS "selesai", supaya urutan "TTS selesai dulu, baru
/// mikrofon dibuka" bisa dibuktikan. [stop] melepas tahanan seperti
/// mesin nyata yang ucapannya dipotong.
class _FakeTtsEngine implements TtsEngine {
  final List<String> spoken = [];
  int stopCalls = 0;
  Completer<void>? hold;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    final pending = hold;
    if (pending != null) await pending.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final pending = hold;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}

/// No-op — tidak boleh menjangkau kanal platform `flutter_foreground_task`
/// sungguhan, yang tidak ada di lingkungan test unit ini.
class _FakeForegroundServiceController implements ForegroundServiceController {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// Konstruktor bersama supaya setiap test tidak perlu mengulang
/// `foregroundService:` — satu-satunya bagian yang benar-benar sama di
/// semua test di berkas ini.
NativeVoiceInput _buildVoice({
  required String? accessKey,
  required SpeechEngine speechEngine,
  required WakeWordEngineFactory createWakeWordEngine,
  TtsEngine? ttsEngine,
}) =>
    NativeVoiceInput(
      accessKey: accessKey,
      speechEngine: speechEngine,
      createWakeWordEngine: createWakeWordEngine,
      ttsEngine: ttsEngine ?? _FakeTtsEngine(),
      foregroundService: _FakeForegroundServiceController(),
    );

void main() {
  group('NativeVoiceInput tanpa AccessKey wake word', () {
    test('startWakeWordWatch tidak menyentuh apa pun bila AccessKey kosong', () async {
      final factory = _FakeWakeWordEngineFactory();
      final voice = _buildVoice(
        accessKey: null,
        speechEngine: _FakeSpeechEngine(),
        createWakeWordEngine: factory.call,
      );

      await voice.startWakeWordWatch();

      expect(factory.created, isEmpty);
      expect(voice.status, VoiceStatus.off);
    });

    test('openWakeWord dianggap terkonfigurasi walau AccessKey kosong', () async {
      // Berbeda dengan lawan palsu di atas, factory nyata tidak bisa
      // dimuat di `flutter test` (plugin ONNX tidak ada). Justru itu
      // buktinya: kalau `_wakeWordConfigured` menolak openWakeWord,
      // startWakeWordWatch kembali diam-diam tanpa mencoba membuat
      // engine, dan tidak ada VoiceFailure sama sekali.
      final voice = _buildVoice(
        accessKey: null,
        speechEngine: _FakeSpeechEngine(),
        createWakeWordEngine: createOpenWakeWordEngine,
      );
      final failures = <VoiceEvent>[];
      final sub = voice.events.where((e) => e is VoiceFailure).listen(failures.add);
      addTearDown(sub.cancel);

      await voice.startWakeWordWatch();
      await _flush();

      expect(failures, isNotEmpty, reason: 'engine seharusnya dicoba dibuat');
      expect(voice.status, VoiceStatus.off);
    });

    test('tombol mikrofon tetap berfungsi walau wake word tidak dikonfigurasi', () async {
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: null,
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
      );

      await voice.startListening();

      expect(speech.listenCalls, 1);
      expect(voice.status, VoiceStatus.listening);
    });
  });

  group('NativeVoiceInput dengan AccessKey wake word', () {
    test('startWakeWordWatch segera setelah konstruksi (meniru auto-start bootstrap) berhasil menyala', () async {
      final factory = _FakeWakeWordEngineFactory();
      final voiceInput = NativeVoiceInput(
        accessKey: 'kunci-uji',
        createWakeWordEngine: factory.call,
        speechEngine: _FakeSpeechEngine(),
        foregroundService: _FakeForegroundServiceController(),
      );

      await voiceInput.startWakeWordWatch();

      expect(voiceInput.status, VoiceStatus.idle);
      expect(factory.created, hasLength(1));
    });

    test('dua startWakeWordWatch bersamaan hanya membuat satu mesin', () async {
      final factory = _FakeWakeWordEngineFactory();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: _FakeSpeechEngine(),
        createWakeWordEngine: factory.call,
      );

      // Pembuatan mesin butuh waktu, jadi panggilan kedua datang selagi yang
      // pertama belum selesai (mis. re-arm otomatis dan tombol batal
      // ditekan hampir bersamaan).
      final first = voice.startWakeWordWatch();
      final second = voice.startWakeWordWatch();
      await Future.wait([first, second]);

      expect(factory.created, hasLength(1));
      expect(voice.status, VoiceStatus.idle);
    });

    test('stopWakeWordWatch selagi mesin masih dibuat tidak meninggalkan mesin yang terus menyala', () async {
      final factory = _FakeWakeWordEngineFactory();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: _FakeSpeechEngine(),
        createWakeWordEngine: factory.call,
      );

      final starting = voice.startWakeWordWatch();
      await voice.stopWakeWordWatch();
      await starting;

      // Mesin yang sempat terbentuk harus ikut dihentikan, bukan lolos dan
      // terus memegang mikrofon.
      expect(factory.created, hasLength(1));
      expect(factory.created.single.stopped, isTrue);
      expect(factory.created.single.deleted, isTrue);
    });

    test('startListening menghentikan pengawasan kata pemicu lebih dulu', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      await voice.startWakeWordWatch();
      expect(factory.created.single.started, isTrue);

      await voice.startListening();

      expect(factory.created.single.stopped, isTrue);
      expect(factory.created.single.deleted, isTrue);
      expect(speech.listenCalls, 1);
      expect(voice.status, VoiceStatus.listening);
    });

    test('kata pemicu terdeteksi memicu WakeWordDetected lalu mulai mendengarkan', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();

      expect(events, contains(isA<WakeWordDetected>()));
      expect(speech.listenCalls, 1);
    });

    test('ucapan akhir memicu FinalTranscript dengan teks yang benar', () async {
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startListening();
      speech.onFinal!('halo wangsa apa kabar');
      await _flush();

      expect(events, contains(isA<FinalTranscript>().having((e) => e.text, 'text', 'halo wangsa apa kabar')));
      expect(voice.status, VoiceStatus.processing);
    });

    test('ucapan sementara memicu PartialTranscript tanpa mengubah status', () async {
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startListening();
      speech.onPartial!('halo');
      await _flush();

      expect(events, contains(isA<PartialTranscript>().having((e) => e.text, 'text', 'halo')));
      expect(voice.status, VoiceStatus.listening);
    });

    test('galat mesin dikte dipetakan ke VoiceFailure, bukan pesan mentah dari plugin', () async {
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startListening();
      speech.onError!('galat native');
      await _flush();

      expect(events, contains(isA<VoiceFailure>().having((e) => e.message, 'message', 'galat native')));
    });

    test('stop membatalkan sesi dikte dan menyalakan kembali pengawasan kata pemicu', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      await voice.startWakeWordWatch();
      await voice.startListening();
      await voice.stop();

      expect(speech.canceled, isTrue);
      // Mesin kata pemicu pertama sudah dihapus saat startListening(),
      // jadi menyalakan kembali berarti membuat satu mesin baru.
      expect(factory.created, hasLength(2));
      expect(factory.created.last.started, isTrue);
      expect(voice.status, VoiceStatus.idle);
    });

    test('ucapan akhir tidak langsung menyalakan kata pemicu: percakapan suara berlanjut', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onFinal!('halo wangsa apa kabar');
      await _flush();

      // Mikrofon dipegang percakapan sampai Agent membalas dan pengguna
      // selesai menjawab, jadi tidak ada mesin kata pemicu kedua.
      expect(factory.created, hasLength(1));
      expect(voice.status, VoiceStatus.processing);
    });

    test('speakReply membacakan balasan lalu membuka mikrofon lagi HANYA setelah TTS selesai', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final tts = _FakeTtsEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
        ttsEngine: tts,
      );

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onFinal!('apa kabar');
      await _flush();

      // Ditahan baru di sini: startListening() memanggil stop() (ketuk mic
      // memotong suara Agent), yang melepas tahanan yang dipasang lebih awal.
      tts.hold = Completer<void>();
      final speaking = voice.speakReply('Baik, terima kasih.');
      await _flush();
      expect(tts.spoken, ['Baik, terima kasih.']);
      // Selagi Agent bicara mikrofon belum boleh dibuka, kalau tidak suara
      // Agent sendiri yang terekam.
      expect(speech.listenCalls, 1);

      tts.hold!.complete();
      await speaking;

      expect(speech.listenCalls, 2);
      expect(voice.status, VoiceStatus.listening);
    });

    test('speakReply membersihkan Markdown sebelum dibacakan', () async {
      final speech = _FakeSpeechEngine();
      final tts = _FakeTtsEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
        ttsEngine: tts,
      );

      await voice.startListening();
      speech.onFinal!('cari info');
      await _flush();
      await voice.speakReply('**Halo** [situs](https://contoh.id)');

      expect(tts.spoken, ['Halo situs']);
    });

    test('balasan untuk pesan yang diketik tidak dibacakan', () async {
      final speech = _FakeSpeechEngine();
      final tts = _FakeTtsEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
        ttsEngine: tts,
      );

      await voice.speakReply('Halo, ini balasan untuk pesan ketikan.');

      expect(tts.spoken, isEmpty);
      expect(speech.listenCalls, 0);
    });

    test('tidak ada ucapan di sesi lanjutan mengakhiri percakapan diam-diam dan menyalakan kata pemicu', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onFinal!('apa kabar');
      await voice.speakReply('Baik.');
      events.clear();

      speech.onError!('error_speech_timeout');
      await _flush();

      // Diam bukan kegagalan: layar cukup menutup lapisan suara (lewat
      // FinalTranscript kosong yang sudah ia tangani), tanpa pesan galat.
      expect(events.whereType<VoiceFailure>(), isEmpty);
      expect(events.whereType<FinalTranscript>().single.text, '');
      expect(factory.created, hasLength(2));
      expect(factory.created.last.started, isTrue);
      expect(voice.status, VoiceStatus.idle);
    });

    test('galat sungguhan tetap dilaporkan sebagai VoiceFailure dan menyalakan kembali kata pemicu', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onError!('error_audio');
      await _flush();

      expect(events.whereType<VoiceFailure>().single.message, 'error_audio');
      expect(factory.created, hasLength(2));
    });

    test('galat lalu ucapan akhir kosong dalam satu sesi hanya menyalakan satu mesin baru', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onError!('error_no_match');
      speech.onFinal!('');
      await _flush();

      expect(factory.created, hasLength(2));
    });

    test('stop selagi Agent bicara memotong TTS, tidak membuka mikrofon lagi, dan menyalakan kata pemicu', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final tts = _FakeTtsEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
        ttsEngine: tts,
      );

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onFinal!('apa kabar');
      await _flush();
      tts.hold = Completer<void>();
      tts.stopCalls = 0;
      final speaking = voice.speakReply('Balasan yang panjang sekali.');
      await _flush();

      await voice.stop();
      await speaking;

      expect(tts.stopCalls, greaterThan(0));
      expect(speech.listenCalls, 1);
      expect(factory.created, hasLength(2));
      expect(voice.status, VoiceStatus.idle);
    });

    test('mengetuk mikrofon selagi Agent bicara memotong suaranya tanpa membuka dikte dua kali', () async {
      final speech = _FakeSpeechEngine();
      final tts = _FakeTtsEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: _FakeWakeWordEngineFactory().call,
        ttsEngine: tts,
      );

      await voice.startListening();
      speech.onFinal!('apa kabar');
      await _flush();
      tts.hold = Completer<void>();
      final speaking = voice.speakReply('Balasan yang panjang sekali.');
      await _flush();
      expect(speech.listenCalls, 1);

      // Pengguna mengetuk tombol mikrofon selagi suara Agent terdengar.
      await voice.startListening();
      await speaking;

      // Satu dari ketukan, bukan satu lagi dari speakReply yang terbangun.
      expect(speech.listenCalls, 2);
    });

    test('endConversation setelah balasan gagal menyalakan kembali kata pemicu', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      await voice.startWakeWordWatch();
      factory.onDetectedCallbacks.single();
      await _flush();
      speech.onFinal!('apa kabar');
      await _flush();
      await voice.endConversation();

      expect(factory.created, hasLength(2));
      expect(voice.status, VoiceStatus.idle);
    });

    test('endConversation tanpa percakapan suara tidak menyalakan apa pun', () async {
      final factory = _FakeWakeWordEngineFactory();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: _FakeSpeechEngine(),
        createWakeWordEngine: factory.call,
      );

      // Mis. balasan untuk pesan yang diketik selesai: tidak boleh
      // menyalakan kata pemicu yang sengaja dimatikan pengguna.
      await voice.endConversation();

      expect(factory.created, isEmpty);
    });

    test('ucapan akhir tidak menyalakan pengawasan kata pemicu bila sebelum dikte memang tidak aktif', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      // Tombol mikrofon ditekan tanpa pengawasan kata pemicu (mis. sakelar
      // "Dengar di latar belakang" dimatikan pengguna).
      await voice.startListening();
      speech.onFinal!('halo');
      await _flush();

      expect(factory.created, isEmpty);
      expect(voice.status, VoiceStatus.processing);
    });

    test('kegagalan membuat mesin kata pemicu dilaporkan sebagai VoiceFailure', () async {
      final factory = _FakeWakeWordEngineFactory()..throwOnCreate = true;
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: _FakeSpeechEngine(),
        createWakeWordEngine: factory.call,
      );
      final events = <VoiceEvent>[];
      voice.events.listen(events.add);

      await voice.startWakeWordWatch();
      await _flush();

      expect(events, contains(isA<VoiceFailure>()));
      expect(voice.status, VoiceStatus.off);
    });

    test('dispose menghentikan kedua mesin dan menutup aliran events', () async {
      final factory = _FakeWakeWordEngineFactory();
      final speech = _FakeSpeechEngine();
      final voice = _buildVoice(
        accessKey: 'kunci-uji',
        speechEngine: speech,
        createWakeWordEngine: factory.call,
      );

      // Berlangganan sebelum dispose(): stream broadcast tidak menjamin
      // pelanggan yang baru datang setelah ditutup ikut menerima `onDone`.
      final doneCompleter = Completer<void>();
      voice.events.listen((_) {}, onDone: doneCompleter.complete);

      await voice.startWakeWordWatch();
      await voice.dispose();

      expect(factory.created.single.stopped, isTrue);
      expect(factory.created.single.deleted, isTrue);
      expect(speech.canceled, isTrue);
      await doneCompleter.future.timeout(const Duration(seconds: 1));
    });
  });
}
