import 'package:flutter/material.dart';
import 'package:siri_orb/orb.dart';

import '../../../voice/voice_input.dart';

/// Bola cahaya di layar mode suara — sejak sesi ini memakai paket
/// `siri_orb` (pub.dev, MIT) alih-alih `CustomPainter` tulisan sendiri.
/// Widget `Orb` yang dipakai (bukan `SiriORB` satunya di paket yang
/// sama), karena `SiriORB` warnanya dikunci ke palet Siri asli
/// (magenta/biru/cyan/ungu) tanpa cara mengubahnya — `Orb` menerima
/// `waveColors` sehingga tetap bisa satu keluarga indigo Wangsa, sama
/// seperti keputusan warna sebelumnya.
///
/// Batasan nyata yang perlu diketahui: `Orb` mengurus animasi putarannya
/// sendiri lewat `AnimationController` privat di dalam paket yang selalu
/// `..repeat()`, tidak menerima controller dari luar — artinya widget ini
/// TIDAK bisa lagi ikut menghormati `MediaQuery.disableAnimations` sama
/// sekali (beda dari versi `CustomPainter` sebelumnya). Ini kompromi
/// yang disadari, bukan kelalaian — lihat catatan di
/// `chat_page_test.dart` soal cakupan test yang dipindah ke
/// `ThinkingIndicator` karena itu.
///
/// [status] membedakan tiga rupa lewat `OrbController.amplitude`
/// (0.0-1.0, lihat paket `siri_orb`): mendengarkan (reaktif ke [level],
/// volume mikrofon asli dari `SoundLevelChanged` di voice_input.dart),
/// memproses (amplitudo tetap tinggi — mic sudah berhenti, tapi orb
/// tetap terasa "hidup"/berpikir), dan diam (amplitudo rendah, napas
/// halus). [hasError] menggeser warna ke arah abu-abu kemerahan.
class VoiceOrb extends StatefulWidget {
  final VoiceStatus status;
  final double level;
  final double size;
  final bool hasError;

  const VoiceOrb({
    super.key,
    required this.status,
    required this.size,
    this.level = 0,
    this.hasError = false,
  });

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> {
  static const _idleAmplitude = 0.08;
  static const _processingAmplitude = 0.55;

  late final OrbController _controller = OrbController(initialAmplitude: _targetAmplitude);

  double get _targetAmplitude => switch (widget.status) {
        VoiceStatus.listening => widget.level.clamp(0.0, 1.0),
        VoiceStatus.processing => _processingAmplitude,
        _ => _idleAmplitude,
      };

  @override
  void didUpdateWidget(covariant VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status || oldWidget.level != widget.level) {
      _controller.amplitude = _targetAmplitude;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.hasError ? Color.lerp(scheme.error, Colors.grey, 0.3)! : scheme.primary;

    return Orb(
      controller: _controller,
      radius: widget.size / 2,
      waveColors: [
        Color.lerp(color, Colors.white, 0.55)!,
        Color.lerp(color, Colors.white, 0.2)!,
        color,
        Color.lerp(color, Colors.black, 0.2)!,
      ],
    );
  }
}
