import 'dart:async';

import 'package:flutter/widgets.dart';

import 'voice_input.dart';

/// Tampilan panggilan ala Siri saat kata pemicu terdeteksi. Satu-satunya
/// berkas yang boleh memakai API notifikasi — lihat alasan pemisahan yang
/// sama di `foreground_service.dart`: mengimpor kanal platform langsung
/// dari logika membuat test unit gagal dengan
/// `MissingPluginException` di lingkungan test.
abstract interface class SummonDisplay {
  /// Meminta izin notifikasi yang dibutuhkan (Android 13+: POST_NOTIFICATIONS,
  /// Android 14+: full-screen intent). Mengembalikan true bila boleh tampil.
  Future<bool> ensurePermissions();

  /// Menampilkan panggilan full-screen "kata pemicu terdengar".
  Future<void> showSummon(String wakeWord);

  /// Menutup panggilan (percakapan selesai / pengguna membuka aplikasi).
  Future<void> hideSummon();
}

/// Membangunkan pengguna ala Siri saat "Hallo Wangsa" terdengar ketika
/// aplikasi sedang di background.
///
/// Cara kerja: [NativeVoiceInput] tetap mendeteksi di isolate utama
/// (layanan latar depan menahan proses), dan [ChatPage] tetap membuka
/// overlay-nya sendiri — kelas ini hanya menambahkan "bel" yang
/// terlihat dari luar aplikasi: notifikasi kategori panggilan dengan
/// `fullScreenIntent`, sehingga di layar kunci/notifikasi muncul
/// heads-up atau layar penuh, dan ketukannya membawa aplikasi ke depan
/// (overlay suara sudah terbuka di sana).
///
/// Tidak melakukan apa pun saat aplikasi di foreground — overlay chat
/// sudah cukup. Tidak dipakai saat aplikasi disingkirkan paksa dari
/// daftar terkini (proses mati, tidak ada yang mendeteksi).
class VoiceSummoner with WidgetsBindingObserver {
  final SummonDisplay _display;
  final String _wakeWord;

  /// Dipanggil setiap aplikasi pindah foreground/background dengan true
  /// bila sedang di background. Dipakai main.dart untuk menunda dikte
  /// otomatis ([NativeVoiceInput.deferAutoListen]) selama di background.
  final void Function(bool backgrounded)? onVisibilityChanged;

  /// Dipanggil saat aplikasi kembali ke depan dengan panggilan yang
  /// tertunda (pengguna mengetuk notifikasi / membuka aplikasi setelah
  /// bel berbunyi). Dipakai main.dart untuk memulai dikte saat itu.
  final Future<void> Function()? onSummonAccepted;

  StreamSubscription<VoiceEvent>? _subscription;
  bool _inForeground = true;
  bool _summonShown = false;
  bool _attached = false;

  VoiceSummoner({
    required SummonDisplay display,
    required String wakeWord,
    this.onVisibilityChanged,
    this.onSummonAccepted,
  }) : _display = display,
       _wakeWord = wakeWord;

  /// Mulai mendengarkan event suara dan perubahan lifecycle. Aman
  /// dipanggil sekali; panggilan berikutnya diabaikan.
  void attach(VoiceInput voiceInput) {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    _subscription = voiceInput.events.listen(_onVoiceEvent);
    unawaited(_display.ensurePermissions());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    final wasBackground = !_inForeground;
    _inForeground = foreground;
    onVisibilityChanged?.call(!foreground);
    if (foreground) {
      unawaited(_display.hideSummon());
      // Kembali dengan bel tertunda = pengguna menerima panggilan:
      // mulai dikte sekarang (pengawasan kata pemicu sudah dilepas
      // oleh startListening sendiri).
      if (wasBackground && _summonShown) {
        _summonShown = false;
        unawaited(onSummonAccepted?.call());
      }
    }
  }

  Future<void> _onVoiceEvent(VoiceEvent event) async {
    switch (event) {
      case WakeWordDetected():
        if (!_inForeground) {
          _summonShown = true;
          await _display.showSummon(_wakeWord);
        }
      case WakeWordStatusChanged():
        break;
      case FinalTranscript():
      case VoiceFailure():
        _summonShown = false;
        await _display.hideSummon();
      case PartialTranscript():
      case SoundLevelChanged():
        break;
    }
  }

  /// Untuk test: mensimulasikan perubahan lifecycle tanpa binding.
  void setForegroundForTest(bool value) => _inForeground = value;

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await _subscription?.cancel();
    _subscription = null;
  }
}
