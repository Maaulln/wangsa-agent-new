/// Adapter tipis di atas `flutter_tts` — satu-satunya berkas yang boleh
/// mengimpor paket itu, alasan yang sama seperti `speech_engine.dart`.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tts/flutter_tts.dart';

import '../api/wangsa_api_client.dart';

/// Kontrak minimal yang dibutuhkan `NativeVoiceInput` dari sebuah mesin
/// pembaca suara. Dideklarasikan eksplisit supaya lawan palsu di test
/// tidak perlu mewarisi dari kelas milik paket itu.
abstract interface class TtsEngine {
  /// Membacakan [text] dan baru selesai (Future terpenuhi) setelah
  /// ucapan habis, atau setelah [stop] memotongnya. Ini yang membedakannya
  /// dari kode TTS lama yang menembak lalu lupa: percakapan berkelanjutan
  /// perlu tahu KAPAN suara Agent selesai supaya mikrofon baru dibuka
  /// sesudahnya, bukan menangkap suara Agent sendiri.
  Future<void> speak(String text);

  /// Memotong ucapan yang sedang berjalan. Aman dipanggil saat diam.
  Future<void> stop();
}

class DeviceTtsEngine implements TtsEngine {
  FlutterTts? _plugin;
  bool _configured = false;

  DeviceTtsEngine({FlutterTts? tts}) : _plugin = tts;

  /// Dibuat saat pertama dipakai, bukan di konstruktor: `FlutterTts()`
  /// langsung memasang handler di platform channel, yang tidak ada di
  /// unit test yang hanya membuat `NativeVoiceInput` tanpa bicara.
  FlutterTts get _tts => _plugin ??= FlutterTts();

  Future<void> _configure() async {
    if (_configured) return;
    // Setelan suara mengikuti kode TTS Yardan sebelumnya
    // (id-ID, kecepatan 0.48).
    await _tts.setLanguage('id-ID');
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    // Tanpa ini speak() langsung kembali sebelum suaranya habis.
    await _tts.awaitSpeakCompletion(true);
    _configured = true;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _configure();
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      // Suara gagal tidak boleh menjatuhkan percakapan: balasannya sudah
      // tampil di layar, jadi cukup dilaporkan ke log.
      debugPrint('[TtsEngine] Gagal membacakan: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// Meminta backend membuat audio balasan, lalu memutarnya di HP. Bila provider
/// TTS server belum tersedia, tetap membacakan balasan dengan suara perangkat.
class BackendTtsEngine implements TtsEngine {
  final WangsaApiClient _api;
  final DeviceTtsEngine _fallback = DeviceTtsEngine();
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completeSubscription;
  Completer<void>? _playbackDone;
  int _requestToken = 0;

  BackendTtsEngine(this._api);

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await stop();
    final requestToken = ++_requestToken;
    final result = await _api.speakText(speechText(text));
    if (requestToken != _requestToken) return;
    final audio = result.dataOrNull;
    if (!result.isSuccess || audio == null || audio.bytes.isEmpty) {
      debugPrint(
        '[BackendTtsEngine] Server TTS gagal; memakai suara perangkat.',
      );
      await _fallback.speak(text);
      return;
    }

    final done = Completer<void>();
    _playbackDone = done;
    _completeSubscription ??= _player.onPlayerComplete.listen((_) {
      final current = _playbackDone;
      if (current != null && !current.isCompleted) current.complete();
    });
    try {
      await _player.play(BytesSource(audio.bytes, mimeType: audio.mimeType));
      await done.future;
    } catch (error) {
      debugPrint('[BackendTtsEngine] Pemutaran audio server gagal: $error');
      await _fallback.speak(text);
    } finally {
      if (identical(_playbackDone, done)) _playbackDone = null;
    }
  }

  @override
  Future<void> stop() async {
    _requestToken++;
    final done = _playbackDone;
    if (done != null && !done.isCompleted) done.complete();
    _playbackDone = null;
    try {
      await _player.stop();
    } catch (_) {}
    await _fallback.stop();
  }
}

/// Mengubah balasan Agent (Markdown) menjadi teks yang enak didengar:
/// tanda `**`, `#`, backtick, dan URL mentah tidak dibacakan huruf per
/// huruf oleh mesin TTS.
String speechText(String markdown) {
  var text = markdown;
  // Blok kode dibuang seluruhnya — membacakan kode tidak berguna.
  text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  // Gambar dibuang, tautan [teks](url) menjadi teksnya saja.
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
  text = text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  text = text.replaceAll(RegExp(r'https?://\S+'), 'tautan');
  text = text.replaceAll('`', '');
  // Penanda judul, kutipan, dan butir daftar di awal baris.
  text = text.replaceAll(
    RegExp(r'^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+', multiLine: true),
    '',
  );
  // Penebal/miring. Garis bawah hanya dihapus di tepi kata supaya
  // `hallo_wangsa` tidak menjadi `hallowangsa`.
  text = text.replaceAll(RegExp(r'\*+'), '');
  text = text.replaceAll(RegExp(r'(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])'), '');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
