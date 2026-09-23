import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Kartu tersendiri untuk blok kode berpagar (```) di balasan Agent,
/// terpisah dari `code` inline (satu kata di antara backtick tunggal,
/// yang tetap memakai gaya pil kecil dari `MarkdownStyleSheet.code` di
/// message_bubble.dart). Blok berpagar diberi label bahasa (kalau LLM
/// menyebutkannya, mis. ```html) dan tombol salin sendiri — sebelum ini
/// cuma ikut gaya `codeblockDecoration` bawaan tanpa cara menyalin
/// isinya kecuali menyalin seluruh balasan.
///
/// Didaftarkan lewat parameter `builders` milik `MarkdownBody` — lihat
/// pemakaiannya di message_bubble.dart.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // element di sini adalah tag <pre>, bukan <code> — lihat catatan
    // _languageOf soal kenapa nama bahasanya harus digali dari anaknya.
    final code = element.textContent;
    return _CodeBlockCard(code: code, language: _languageOf(element));
  }

  /// Markdown standar menaruh kelas `language-xxx` pada elemen <code> di
  /// DALAM <pre>, bukan pada <pre> itu sendiri — mengikuti konvensi
  /// CommonMark/highlight.js yang dipakai paket `markdown`.
  String? _languageOf(md.Element pre) {
    for (final child in pre.children ?? const []) {
      if (child is md.Element && child.tag == 'code') {
        final className = child.attributes['class'];
        if (className != null && className.startsWith('language-')) {
          return className.substring('language-'.length);
        }
      }
    }
    return null;
  }
}

class _CodeBlockCard extends StatelessWidget {
  final String code;
  final String? language;

  const _CodeBlockCard({required this.code, this.language});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Parser markdown menyertakan satu baris baru penutup di textContent
    // blok berpagar — dibuang supaya tidak ada baris kosong menggantung
    // di ujung kartu.
    final trimmed = code.endsWith('\n')
        ? code.substring(0, code.length - 1)
        : code;

    // width: double.infinity, bukan sekadar membiarkan Container
    // menyesuaikan diri — balasan Agent dibungkus Column dengan
    // crossAxisAlignment.start (lihat _AgentAnswer di message_bubble.dart),
    // jadi tanpa ini kartu ikut selebar baris kode terpanjang di dalam
    // SingleChildScrollView horizontal, bukan selebar layar. Baris
    // panjangnya seharusnya di-scroll DI DALAM kartu, bukan membuat
    // kartunya sendiri melebar sampai kepotong di tepi layar.
    return SizedBox(
      width: double.infinity,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      (language == null || language!.isEmpty)
                          ? 'kode'
                          : language!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: trimmed));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(
                            content: Text('Kode disalin ke clipboard.'),
                          ),
                        );
                    },
                    tooltip: 'Salin kode',
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    color: scheme.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outline.withValues(alpha: 0.4)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text(
                trimmed,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: scheme.onSurface,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
