import 'package:flutter/material.dart';
import '../../../theme/wangsa_theme.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../chat_icons.dart';

/// Komponen penampil keadaan kosong, galat, dan tidak ditemukan.
///
/// `DESIGN.md` bagian 15 dan 16 mewajibkan status tidak boleh hanya
/// dibedakan lewat warna — harus selalu berupa kombinasi ikon, judul,
/// dan teks penjelas. Untuk keadaan galat, latar `errorContainer` dipakai
/// agar kontras dengan permukaan netral tanpa terasa mencolok seperti
/// spanduk bahaya di dashboard konvensional.
class ChatNotice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final bool isError;
  final Widget? extra;
  // Hanya dipakai oleh .empty() — lambang angsa (assets/logo.svg, sama
  // dengan sumber ikon launcher + splash screen Android) menggantikan
  // `icon` sebagai sambutan layar chat kosong, ala Claude/ChatGPT yang
  // menampilkan mereknya sendiri di tengah chat baru.
  final bool _useLogo;

  const ChatNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.isError = false,
    this.extra,
  }) : _useLogo = false;

  const ChatNotice.empty({
    super.key,
    this.icon = ChatIcons.history,
    this.title = 'Mulai percakapan',
    this.detail = 'Ketik pesan, atau tekan tombol mikrofon lalu bicara.',
  }) : isError = false,
       extra = null,
       _useLogo = true;

  const ChatNotice.notFound({
    super.key,
    this.icon = ChatIcons.bot,
    this.title = 'Agent tidak tersedia',
    this.detail =
        'Agent ini tidak ada, atau belum dipublikasikan. Periksa id Agent di layar pengaturan.',
    this.extra,
  }) : isError = false,
       _useLogo = false;

  const ChatNotice.failed({
    super.key,
    this.icon = ChatIcons.error,
    this.title = 'Gagal terhubung',
    required this.detail,
    this.extra,
  }) : isError = true,
       _useLogo = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (isError) {
      final errorCard = Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(WangsaRadius.md),
          border: Border.all(color: scheme.error.withValues(alpha: 0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.onErrorContainer),
            const SizedBox(height: 12),
            Text(
              title,
              style: textTheme.titleMedium?.copyWith(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );

      // Bila tidak ada blok tambahan (mis. konfigurasi berhasil dimuat namun
      // API gagal), tampilkan tata letak awal tanpa scrollview berlebih.
      if (extra == null) {
        return Center(
          child: Padding(padding: const EdgeInsets.all(24), child: errorCard),
        );
      }

      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [errorCard, const SizedBox(height: 16), extra!],
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logoColor = isDark
        ? const Color(0xFFFAFAFA)
        : const Color(0xFF09090B);

    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        _useLogo
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final availableWidth = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : 420.0;
                  final size = availableWidth < 420.0 ? availableWidth : 420.0;
                  return SvgPicture.asset(
                    'assets/logo.svg',
                    width: size,
                    height: size,
                    fit: BoxFit.contain,
                    colorFilter: ColorFilter.mode(logoColor, BlendMode.srcIn),
                  );
                },
              )
            : Icon(icon, size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          style: textTheme.titleMedium?.copyWith(
            color: scheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        if (extra != null) ...[const SizedBox(height: 24), extra!],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 800.0;
        // Geser konten sedikit ke atas dari tengah: padding atas ~35%,
        // sisanya di bawah. Nilai ini membuat grup logo+teks tampak
        // berada di sepertiga-atas-bawah layar, ala referensi desain.
        final topPad = (available * 0.35).clamp(48.0, 240.0);
        final botPad = (available * 0.55).clamp(48.0, 360.0);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(32, topPad, 32, botPad),
          child: content,
        );
      },
    );
  }
}

/// Blok informasi ketika aplikasi beralih ke konfigurasi cadangan.
///
/// Pengguna yang menemui kegagalan koneksi atau penolakan Agent sering kali
/// tidak tahu bahwa penyebabnya adalah konfigurasi server yang gagal dimuat,
/// sehingga aplikasi mencoba alamat cadangan bawaan. Blok ini menyajikan
/// penyebab kegagalan, alamat API yang sedang dicoba, serta panduan ke layar
/// Pengaturan agar pengguna tidak perlu menebak apa yang terjadi.
class FallbackConfigNotice extends StatelessWidget {
  final String problem;
  final String apiBaseUrl;

  const FallbackConfigNotice({
    super.key,
    required this.problem,
    required this.apiBaseUrl,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(WangsaRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(ChatIcons.info, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Memakai konfigurasi cadangan',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            problem,
            style: textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
          const SizedBox(height: 6),
          Text(
            apiBaseUrl,
            style: textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Buka layar Pengaturan untuk memeriksa konfigurasi.',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Spanduk galat sebaris untuk pesan galat sesaat (misalnya saat pengiriman gagal).
class ChatErrorBanner extends StatelessWidget {
  final String message;

  const ChatErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(WangsaRadius.sm),
        border: Border.all(color: scheme.error.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(ChatIcons.error, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
