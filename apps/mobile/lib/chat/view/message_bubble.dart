import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../bloc/chat_bloc.dart';
import 'widgets/code_block.dart';
import 'widgets/reply_file_list.dart';
import 'widgets/reply_image_gallery.dart';

/// Giliran pengguna tetap gelembung (dipindahkan dari rancangan Yardan:
/// sudut lebih membulat pada sisi lawan bicara, bayangan tipis). Giliran
/// Agent SENGAJA tanpa gelembung sejak 2026-09-15 — teks polos rata kiri
/// ala Claude/ChatGPT, karena balasan panjang di dalam kotak berlatar
/// terasa sesak dibanding teks yang mengalir bebas. Warnanya tetap lewat
/// `WangsaTheme` supaya ikut mode gelap/terang sistem.
///
/// Isinya dirender lewat `flutter_markdown_plus` (BSD-3, open source,
/// tanpa API key — lihat catatan lisensi di
/// docs/wake-word-setup-mobile.md soal kenapa itu diperiksa), bukan
/// `Text` polos. Balasan Agent sering datang berformat markdown dari LLM
/// (`**tebal**`, daftar, dst.) — sebelum ini formatnya tidak pernah
/// dirender, tampil sebagai tanda baca mentah atau hilang begitu saja.
class MessageBubble extends StatelessWidget {
  final Turn turn;

  const MessageBubble({super.key, required this.turn});

  @override
  Widget build(BuildContext context) {
    final fromUser = turn.role == TurnRole.user;
    return fromUser ? _UserBubble(turn: turn) : _AgentAnswer(turn: turn);
  }
}

class _UserBubble extends StatelessWidget {
  final Turn turn;

  const _UserBubble({required this.turn});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        // 20, bukan 8 — sebelumnya balasan Agent (atau ThinkingIndicator
        // selagi menunggu) langsung menempel di bawah pesan pengguna,
        // terasa sesak.
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(5),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.05),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (turn.imageCount > 0)
              Padding(
                padding: EdgeInsets.only(
                  bottom: turn.content.isEmpty ? 0 : 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_outlined,
                      size: 14,
                      color: scheme.onPrimary.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      turn.imageCount == 1 ? '1 gambar' : '${turn.imageCount} gambar',
                      style: TextStyle(
                        color: scheme.onPrimary.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            if (turn.content.isNotEmpty)
              Text(
                turn.content,
                style: TextStyle(color: scheme.onPrimary, height: 1.4),
              ),
          ],
        ),
      ),
    );
  }
}

/// Balasan Agent: markdown polos rata kiri, hampir selebar layar (tidak
/// dibatasi 80% seperti gelembung pengguna — tidak ada kotak yang perlu
/// disisakan ruang di sampingnya), plus baris tombol aksi di bawahnya.
class _AgentAnswer extends StatelessWidget {
  final Turn turn;

  const _AgentAnswer({required this.turn});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseStyle = TextStyle(color: scheme.onSurface, height: 1.4);

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (turn.images.isNotEmpty) ...[
              ReplyImageGallery(images: turn.images),
              if (turn.content.isNotEmpty) const SizedBox(height: 8),
            ],
            MarkdownBody(
              data: turn.content,
              // Balasan LLM sering memisah paragraf dengan satu baris baru,
              // bukan baris kosong ganda ala markdown baku — tanpa ini,
              // baris-baris itu akan menyatu jadi satu paragraf panjang.
              softLineBreak: true,
              // Blok kode berpagar (```) dapat kartu sendiri dengan label
              // bahasa dan tombol salin — lihat widgets/code_block.dart.
              // `code` inline (satu kata di antara backtick tunggal) TIDAK
              // ikut builder ini, tetap gaya pil kecil dari styleSheet.code
              // di bawah.
              builders: {'pre': CodeBlockBuilder()},
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: baseStyle,
                    strong: baseStyle.copyWith(fontWeight: FontWeight.bold),
                    em: baseStyle.copyWith(fontStyle: FontStyle.italic),
                    listBullet: baseStyle,
                    code: baseStyle.copyWith(
                      fontFamily: 'monospace',
                      backgroundColor: scheme.onSurface.withValues(alpha: 0.1),
                    ),
                    blockquote: baseStyle.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.75),
                    ),
                    h1: baseStyle.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: baseStyle.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: baseStyle.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
            ),
            if (turn.files.isNotEmpty) ...[
              const SizedBox(height: 8),
              ReplyFileList(files: turn.files),
            ],
            const SizedBox(height: 6),
            _ActionRow(text: turn.content),
          ],
        ),
      ),
    );
  }
}

/// Ikon aksi ala Claude/ChatGPT di bawah tiap balasan. Hanya Salin dan
/// Bagikan yang sungguhan berfungsi — keduanya murni fitur klien, tidak
/// butuh apa pun dari backend. Suka/tidak suka dan bacakan (TTS) diberi
/// info "belum tersedia" saat diketuk alih-alih diam, mengikuti pola yang
/// sama dengan tombol lampiran di composer: bukan tombol pura-pura yang
/// diam saja, tapi juga tidak berpura-pura berfungsi. Wangsa tidak punya
/// endpoint untuk menyimpan umpan balik (lihat docs/API.md), dan tombol
/// Bacakan per gelembung belum ada: TTS baru hidup untuk percakapan suara
/// berkelanjutan (lihat README.md) — jadi menu titik-tiga ala Claude yang isinya semua
/// hal semacam itu tidak ditambahkan sama sekali di sini, daripada berisi
/// item yang tidak satu pun nyata.
class _ActionRow extends StatelessWidget {
  final String text;

  const _ActionRow({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionIcon(
          icon: Icons.copy_outlined,
          tooltip: 'Salin',
          color: scheme.onSurfaceVariant,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(content: Text('Disalin ke clipboard.')),
              );
          },
        ),
        _ActionIcon(
          icon: Icons.thumb_up_outlined,
          tooltip: 'Suka',
          color: scheme.onSurfaceVariant,
          onTap: () => _notAvailableYet(context, 'Umpan balik'),
        ),
        _ActionIcon(
          icon: Icons.thumb_down_outlined,
          tooltip: 'Tidak suka',
          color: scheme.onSurfaceVariant,
          onTap: () => _notAvailableYet(context, 'Umpan balik'),
        ),
        _ActionIcon(
          icon: Icons.volume_up_outlined,
          tooltip: 'Bacakan',
          color: scheme.onSurfaceVariant,
          onTap: () => _notAvailableYet(context, 'Balasan suara'),
        ),
        _ActionIcon(
          icon: Icons.share_outlined,
          tooltip: 'Bagikan',
          color: scheme.onSurfaceVariant,
          onTap: () =>
              unawaited(SharePlus.instance.share(ShareParams(text: text))),
        ),
      ],
    );
  }

  void _notAvailableYet(BuildContext context, String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what belum tersedia.')));
  }
}

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      color: color,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      splashRadius: 18,
    );
  }
}
