import 'package:flutter/material.dart';

import '../../../api/models.dart';

/// Baris pratinjau gambar yang dikirim Agent bersama balasan (screenshot,
/// hasil image_gen, dst. — lihat [ReplyImage] dan
/// `plugins/platforms/wangsa_mobile/adapter.py`, bagian "Outbound
/// images"). Diketuk untuk membuka pratinjau layar penuh dengan
/// pencet-cubit (pinch-zoom).
class ReplyImageGallery extends StatelessWidget {
  final List<ReplyImage> images;

  const ReplyImageGallery({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final image in images) _ImageThumbnail(image: image)],
    );
  }
}

class _ImageThumbnail extends StatelessWidget {
  final ReplyImage image;

  const _ImageThumbnail({required this.image});

  ImageProvider? get _provider {
    if (image.bytes != null) return MemoryImage(image.bytes!);
    final url = image.url;
    if (url != null && url.isNotEmpty) return NetworkImage(url);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = _provider;

    return GestureDetector(
      onTap: provider == null
          ? null
          : () => Navigator.of(context).push(
                _ImagePreviewRoute(provider: provider, caption: image.caption),
              ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 140,
          height: 140,
          color: scheme.surfaceContainerHighest,
          child: provider == null
              ? Icon(
                  Icons.broken_image_outlined,
                  color: scheme.onSurfaceVariant,
                )
              : Image(
                  image: provider,
                  fit: BoxFit.cover,
                  // Gambar berbasis URL jarang gagal setelah diterima, tapi
                  // bisa saja tautannya sudah kedaluwarsa — tampilkan
                  // lambang rusak alih-alih layar merah galat Flutter.
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Layar penuh transparan (bukan [MaterialPageRoute] biasa) supaya latar
/// percakapan tetap terlihat redup di baliknya, mengikuti pola pratinjau
/// gambar yang umum di aplikasi pesan.
class _ImagePreviewRoute extends PageRouteBuilder<void> {
  _ImagePreviewRoute({required ImageProvider provider, String? caption})
      : super(
          opaque: false,
          barrierColor: Colors.black87,
          transitionDuration: const Duration(milliseconds: 180),
          pageBuilder: (context, animation, secondaryAnimation) =>
              _ImagePreviewScreen(provider: provider, caption: caption),
        );
}

class _ImagePreviewScreen extends StatelessWidget {
  final ImageProvider provider;
  final String? caption;

  const _ImagePreviewScreen({required this.provider, this.caption});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 5,
                  // Menelan ketukan di atas gambar itu sendiri supaya
                  // pencet-cubit tidak ikut menutup layar — hanya ketukan
                  // di area kosong di sekitarnya yang menutup.
                  child: GestureDetector(
                    onTap: () {},
                    child: Image(image: provider),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              if (caption != null && caption!.trim().isNotEmpty)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 24,
                  child: Text(
                    caption!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
