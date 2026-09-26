import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../api/models.dart';
import '../chat_icons.dart';

/// Daftar kartu dokumen/audio yang dikirim Agent bersama balasan (bukan
/// gambar — lihat `ReplyImageGallery` untuk itu). Lihat [ReplyFile] dan
/// `plugins/platforms/wangsa_mobile/adapter.py`, bagian "Outbound
/// images/files/audio".
class ReplyFileList extends StatelessWidget {
  final List<ReplyFile> files;

  const ReplyFileList({super.key, required this.files});

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final file in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: file.isAudio
                ? _AudioFileCard(file: file)
                : _DocumentFileCard(file: file),
          ),
      ],
    );
  }
}

class _DocumentFileCard extends StatelessWidget {
  final ReplyFile file;

  const _DocumentFileCard({required this.file});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = file.bytes;

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            bytes == null ? Icons.error_outline : Icons.description_outlined,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  file.filename,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (file.caption != null && file.caption!.trim().isNotEmpty)
                  Text(
                    file.caption!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          if (bytes != null) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(ChatIcons.share, size: 20),
              tooltip: 'Bagikan',
              color: scheme.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              onPressed: () => _share(bytes),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _share(List<int> bytes) async {
    final xfile = XFile.fromData(
      Uint8List.fromList(bytes),
      name: file.filename,
      mimeType: file.mimeType,
    );
    await SharePlus.instance.share(
      ShareParams(files: [xfile], fileNameOverrides: [file.filename]),
    );
  }
}

class _AudioFileCard extends StatefulWidget {
  final ReplyFile file;

  const _AudioFileCard({required this.file});

  @override
  State<_AudioFileCard> createState() => _AudioFileCardState();
}

class _AudioFileCardState extends State<_AudioFileCard> {
  VideoPlayerController? _controller;
  bool _loading = false;
  String? _error;

  // Bilah waveform simulasi
  static const List<double> _waveformHeights = [
    0.3,
    0.6,
    0.4,
    0.8,
    0.5,
    0.9,
    0.7,
    0.4,
    0.6,
    0.85,
    0.55,
    0.75,
    0.45,
    0.9,
    0.65,
    0.35,
    0.7,
    0.5,
  ];

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller != null) {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position >= controller.value.duration) {
          await controller.seekTo(Duration.zero);
        }
        await controller.play();
      }
      setState(() {});
      return;
    }

    final bytes = widget.file.bytes;
    if (bytes == null) return;

    setState(() => _loading = true);
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/wangsa_reply_audio_${DateTime.now().microsecondsSinceEpoch}_${widget.file.filename}';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      final newController = VideoPlayerController.file(file);
      await newController.initialize();
      newController.addListener(() {
        if (mounted) setState(() {});
      });
      await newController.play();
      if (!mounted) {
        await newController.dispose();
        return;
      }
      setState(() {
        _controller = newController;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Audio tidak bisa diputar.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    final isPlaying = controller?.value.isPlaying ?? false;
    final duration = controller?.value.duration ?? Duration.zero;
    final position = controller?.value.position ?? Duration.zero;
    final double progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: _loading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  )
                : Icon(
                    widget.file.bytes == null
                        ? Icons.error_outline
                        : (isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                  ),
            iconSize: 32,
            color: scheme.primary,
            onPressed: widget.file.bytes == null || _loading
                ? null
                : _togglePlayback,
          ),
          const SizedBox(width: 4),
          // Waveform bars
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 22,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(_waveformHeights.length, (index) {
                      final barRatio = (index + 1) / _waveformHeights.length;
                      final isActive = progress >= barRatio;
                      return Container(
                        width: 3,
                        height: 22 * _waveformHeights[index],
                        decoration: BoxDecoration(
                          color: isActive
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _error ??
                          (controller != null
                              ? _formatDuration(position)
                              : (widget.file.caption?.trim().isNotEmpty == true
                                    ? widget.file.caption!
                                    : 'Audio klip')),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (controller != null)
                      Text(
                        _formatDuration(duration),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
