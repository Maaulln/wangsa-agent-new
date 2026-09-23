import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Baris "sedang memproses", muncul di posisi yang akan ditempati
/// balasan Agent berikutnya — bagian dari alur pesan itu sendiri, bukan
/// baris terpisah di bawah daftar chat. Terinspirasi dari baris "Thought
/// process" di aplikasi Claude, TAPI sengaja tanpa panah untuk dibuka:
/// baris itu di Claude membuka jejak penalaran sungguhan, sedangkan API
/// Wangsa cuma mengembalikan jawaban akhir (`AgentReply.response`, lihat
/// `api/models.dart`) — tidak ada isi penalaran untuk ditampilkan. Panah
/// yang tidak membuka apa-apa adalah tombol pura-pura, jadi tidak
/// ditambahkan.
///
/// [avatarAnimation] menggerakkan denyut halus pada ikon di kiri — dioper
/// dari `_waveController` milik [ChatPage] supaya tidak perlu ticker baru.
/// Ikonnya sendiri `assets/video/loading_chat.mp4`, video looping bisu
/// (`VideoPlayer`, paket resmi tim Flutter, open source tanpa API key),
/// diputar terus selagi widget ini hidup — denyut skala dari
/// [avatarAnimation] tetap jalan di atasnya, bukan pengganti.
///
/// Kata dipilih ACAK (bukan urutan tetap) tiap dua detik lewat
/// `Timer.periodic`, tidak pernah kata yang sama dua kali berturut-turut.
/// Titik di belakangnya ("Berpikir", lalu "Berpikir.", "Berpikir..",
/// "Berpikir...", berulang) berjalan sendiri lewat timer terpisah yang
/// lebih cepat — itu yang membuatnya "terus muncul satu per satu", bukan
/// menempel diam sebagai bagian dari kata. Keduanya terpisah dari
/// [avatarAnimation] — ini teks berjalan (menandakan masih hidup), bukan
/// gerak dekoratif, jadi kata tetap berganti walau pengguna minta gerak
/// berkurang di sistemnya; hanya animasi titik dan transisi antar-katanya
/// yang dihentikan/dipangkas instan saat itu terjadi.
class ThinkingIndicator extends StatefulWidget {
  final Animation<double> avatarAnimation;

  const ThinkingIndicator({super.key, required this.avatarAnimation});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator> {
  static const _words = [
    'Berpikir',
    'Tinkering',
    'Cooking',
    'Goosing',
    'Quackaring',
    'Six Seven',
  ];
  static final _random = math.Random();

  late String _word;
  int _dotCount = 1;
  Timer? _wordTimer;
  Timer? _dotTimer;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _word = _words[_random.nextInt(_words.length)];
    _wordTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      setState(() => _word = _pickNextWord());
    });
  }

  String _pickNextWord() {
    if (_words.length == 1) return _words.first;
    String next;
    do {
      next = _words[_random.nextInt(_words.length)];
    } while (next == _word);
    return next;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // DESIGN.md §15/16: gerak dekoratif berhenti kalau pengguna minta
    // gerak berkurang di sistemnya. Titik yang berdenyut termasuk itu;
    // kata yang berganti tidak (itu informasi status, bukan hiasan).
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) {
      _dotTimer?.cancel();
      _dotTimer = null;
      _dotCount = 3;
    } else {
      _dotTimer ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
        setState(() => _dotCount = _dotCount % 3 + 1);
      });
    }
  }

  @override
  void dispose() {
    _wordTimer?.cancel();
    _dotTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Avatar(animation: widget.avatarAnimation),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            // Kunci widget berdasarkan kata saja, bukan jumlah titik —
            // supaya transisi memudar cuma terjadi saat KATA berganti,
            // sedangkan titik memperbarui teksnya langsung tanpa animasi
            // masuk/keluar (persis kesan "berjalan" yang diminta).
            duration: _reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 200),
            child: Text(
              '$_word${'.' * _dotCount}',
              key: ValueKey(_word),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Slot ikon terpisah, sengaja jadi widget sendiri — lihat catatan kelas
/// di atas. Butuh `State` sendiri (bukan `StatelessWidget` seperti
/// sebelumnya) karena `VideoPlayerController` perlu diinisialisasi
/// (asinkron) dan dilepas eksplisit lewat `dispose()`.
class _Avatar extends StatefulWidget {
  final Animation<double> animation;

  const _Avatar({required this.animation});

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> {
  static const _size = 26.0;

  late final VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset('assets/video/loading_chat.mp4')
      ..setLooping(true)
      // Bisu sengaja — ini ikon status di daftar chat, bukan pemutar
      // media, suara dari situ akan terasa aneh dan tidak diminta.
      ..setVolume(0)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        unawaited(_controller.play());
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        // Denyut halus 0.92-1.0, bukan 0-1 penuh — cukup terasa hidup
        // tanpa mengalihkan perhatian dari teksnya sendiri.
        final scale =
            0.92 +
            (0.08 *
                (0.5 +
                    0.5 * Curves.easeInOut.transform(widget.animation.value)));
        return Transform.scale(scale: scale, child: child);
      },
      child: ClipOval(
        child: SizedBox(
          width: _size,
          height: _size,
          child: _controller.value.isInitialized
              ? FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller.value.size.width,
                    height: _controller.value.size.height,
                    child: VideoPlayer(_controller),
                  ),
                )
              // Sekejap sebelum video selesai dimuat — kosong, bukan
              // gambar statis yang lalu tertimpa, supaya tidak ada
              // kedipan ganti aset di layar.
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
