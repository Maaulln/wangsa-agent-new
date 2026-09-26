import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../api/models.dart';
import '../chat_icons.dart';

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
              _ImagePreviewRoute(
                provider: provider,
                caption: image.caption,
                image: image,
              ),
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

/// Layar penuh transparan supaya latar percakapan tetap terlihat redup di baliknya.
class _ImagePreviewRoute extends PageRouteBuilder<void> {
  _ImagePreviewRoute({
    required ImageProvider provider,
    String? caption,
    required ReplyImage image,
  }) : super(
         opaque: false,
         barrierColor: Colors.black87,
         transitionDuration: const Duration(milliseconds: 180),
         pageBuilder: (context, animation, secondaryAnimation) =>
             _ImagePreviewScreen(
               provider: provider,
               caption: caption,
               image: image,
             ),
       );
}

class _ImagePreviewScreen extends StatelessWidget {
  final ImageProvider provider;
  final String? caption;
  final ReplyImage image;

  const _ImagePreviewScreen({
    required this.provider,
    this.caption,
    required this.image,
  });

  Future<void> _share() async {
    if (image.bytes != null) {
      final xfile = XFile.fromData(
        image.bytes!,
        name: image.filename,
        mimeType: image.mimeType,
      );
      await SharePlus.instance.share(
        ShareParams(files: [xfile], fileNameOverrides: [image.filename]),
      );
    } else if (image.url != null && image.url!.isNotEmpty) {
      await SharePlus.instance.share(ShareParams(text: image.url!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 5,
                child: Image(image: provider),
              ),
            ),
            // Header bar
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            ChatIcons.share,
                            color: Colors.white,
                          ),
                          tooltip: 'Bagikan',
                          onPressed: _share,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                          ),
                          tooltip: 'Tutup',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (caption != null && caption!.trim().isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    caption!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
