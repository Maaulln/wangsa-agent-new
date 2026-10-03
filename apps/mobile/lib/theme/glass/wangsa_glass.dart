import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Glassmorphism Wangsa, mengikuti prinsip UXPilot ("Glassmorphism UI"):
///
/// * Glass hanya untuk elemen kunci (bar, composer, sheet, overlay) —
///   teks baca (balasan, markdown, kode, daftar pengaturan) tetap solid.
/// * Blur moderat (8–15) + lapisan tint semi-transparan 10–18% (gelap) /
///   60–75% (terang) di belakang teks, supaya kontras terjaga.
/// * Satu arah cahaya (kiri-atas): kilau gradien + rim 1px yang memudar
///   ke kanan-bawah. Rim mode gelap berwarna indigo muda, BUKAN putih murni.
/// * Latar di belakang kaca dirancang ([GlassBackdrop]): blob indigo/biru
///   statis berluminans rendah — jangan dianimasikan (blur + animasi = jank)
///   dan jangan ditumpuk di belakang teks.
/// * Fallback solid saat kontras tinggi (MediaQuery.highContrast).
///
/// Kontras teks di atas glass (WCAG, dihitung untuk puncak blob terburuk):
/// gelap — putih ≥ 9:1, teks sekunder #C7C7CC ≥ 5:1; terang — #18181B ≥ 14:1,
/// sekunder #52525B ≥ 6:1. Jangan memakai #8E8E93 / #71717A di atas glass.
enum GlassLevel { card, bar, sheet }

@immutable
class GlassStyle {
  const GlassStyle({
    required this.sigma,
    required this.tintAlpha,
    required this.rimAlpha,
  });

  final double sigma;
  final double tintAlpha;
  final double rimAlpha;
}

@immutable
class WangsaGlass extends ThemeExtension<WangsaGlass> {
  const WangsaGlass({
    required this.backdropBase,
    required this.blobA,
    required this.blobB,
    required this.tint,
    required this.rim,
    required this.solid,
    required this.solidBorder,
    required this.onGlass,
    required this.onGlassMuted,
    required this.card,
    required this.bar,
    required this.sheet,
  });

  final Color backdropBase;
  final Color blobA;
  final Color blobB;
  final Color tint;
  final Color rim;
  final Color solid;
  final Color solidBorder;
  final Color onGlass;
  final Color onGlassMuted;
  final GlassStyle card;
  final GlassStyle bar;
  final GlassStyle sheet;

  static const dark = WangsaGlass(
    backdropBase: Color(0xFF05060F),
    blobA: Color(0x664F46E5), // indigo @40%
    blobB: Color(0x380A84FF), // biru @22%
    tint: Color(0xFFFFFFFF),
    rim: Color(0xFFC7D2FE),
    solid: Color(0xFF1C1C1E),
    solidBorder: Color(0xFF2C2C2E),
    onGlass: Color(0xFFFFFFFF),
    onGlassMuted: Color(0xFFC7C7CC),
    card: GlassStyle(sigma: 8, tintAlpha: 0.10, rimAlpha: 0.16),
    bar: GlassStyle(sigma: 12, tintAlpha: 0.14, rimAlpha: 0.20),
    sheet: GlassStyle(sigma: 15, tintAlpha: 0.18, rimAlpha: 0.24),
  );

  static const light = WangsaGlass(
    backdropBase: Color(0xFFF5F7FF),
    blobA: Color(0x73818CF8), // indigo muda @45%
    blobB: Color(0x4D60A5FA), // biru muda @30%
    tint: Color(0xFFFFFFFF),
    rim: Color(0xFF4F46E5),
    solid: Color(0xFFFFFFFF),
    solidBorder: Color(0xFFE4E4E7),
    onGlass: Color(0xFF18181B),
    onGlassMuted: Color(0xFF52525B),
    card: GlassStyle(sigma: 10, tintAlpha: 0.60, rimAlpha: 0.14),
    bar: GlassStyle(sigma: 14, tintAlpha: 0.65, rimAlpha: 0.16),
    sheet: GlassStyle(sigma: 15, tintAlpha: 0.75, rimAlpha: 0.18),
  );

  static WangsaGlass of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<WangsaGlass>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  GlassStyle styleOf(GlassLevel level) => switch (level) {
    GlassLevel.card => card,
    GlassLevel.bar => bar,
    GlassLevel.sheet => sheet,
  };

  @override
  WangsaGlass copyWith() => this;

  @override
  WangsaGlass lerp(ThemeExtension<WangsaGlass>? other, double t) =>
      other is WangsaGlass && t >= 0.5 ? other : this;
}

/// Permukaan kaca: blur latar + tint + kilau satu arah + rim 1px.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.level = GlassLevel.card,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
  });

  final Widget child;
  final GlassLevel level;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final glass = WangsaGlass.of(context);
    final style = glass.styleOf(level);
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    if (MediaQuery.highContrastOf(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: glass.solid,
          borderRadius: borderRadius,
          border: Border.all(color: glass.solidBorder),
        ),
        child: content,
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: style.sigma, sigmaY: style.sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            // Cahaya dari kiri-atas: sisi atas-kiri sedikit lebih terang.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                glass.tint.withValues(alpha: style.tintAlpha + 0.06),
                glass.tint.withValues(alpha: style.tintAlpha - 0.02),
              ],
            ),
            border: Border.all(
              color: glass.rim.withValues(alpha: style.rimAlpha),
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Permukaan kaca untuk bottom sheet (sudut atas membulat + SafeArea).
/// Pasangkan dengan `showModalBottomSheet(backgroundColor: Colors.transparent)`.
class GlassSheetSurface extends StatelessWidget {
  const GlassSheetSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      level: GlassLevel.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(child: child),
    );
  }
}

/// Scrim berkaca untuk overlay layar penuh (mis. lapisan suara): blur + redup.
class GlassScrim extends StatelessWidget {
  const GlassScrim({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
    this.sigma = 14,
    this.dim = 0.55,
  });

  final Widget child;
  final AlignmentGeometry alignment;
  final double sigma;
  final double dim;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.highContrastOf(context)) {
      return Container(
        color: Colors.black.withValues(alpha: 0.88),
        alignment: alignment,
        child: child,
      );
    }
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: Container(
        color: Colors.black.withValues(alpha: dim),
        alignment: alignment,
        child: child,
      ),
    );
  }
}

/// Latar ambient di belakang kaca: dasar gelap/terang + dua blob radial
/// statis di sudut berlawanan (tidak pernah saling menumpuk di belakang teks).
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = WangsaGlass.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: glass.backdropBase),
              Positioned(
                top: -140,
                left: -100,
                child: _Blob(color: glass.blobA, size: 380),
              ),
              Positioned(
                bottom: -160,
                right: -120,
                child: _Blob(color: glass.blobB, size: 420),
              ),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
