import 'package:flutter/material.dart';
import '../../../theme/wangsa_theme.dart';

import '../../../api/models.dart';
import '../chat_icons.dart';

/// Jejak ringkas tool yang sudah dipakai pada jawaban ini.
class ToolCallCard extends StatefulWidget {
  final ToolCallInfo toolCall;

  const ToolCallCard({super.key, required this.toolCall});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  String get _label {
    final tool = widget.toolCall.tool.toLowerCase();
    if (tool.contains('extract') ||
        tool.contains('browser') ||
        tool.contains('navigate')) {
      return 'Membuka halaman web';
    }
    if (tool.contains('search') || tool.contains('web')) {
      return 'Mencari di web';
    }
    if (tool.contains('file') ||
        tool.contains('read') ||
        tool.contains('write')) {
      return 'Membaca atau mengelola file';
    }
    if (tool.contains('terminal') ||
        tool.contains('command') ||
        tool.contains('exec')) {
      return 'Menjalankan perintah';
    }
    if (tool.contains('image') || tool.contains('photo')) {
      return 'Memproses gambar';
    }
    return 'Menggunakan ${widget.toolCall.tool}';
  }

  IconData get _icon {
    return ChatIcons.forTool(widget.toolCall.tool);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPreview = widget.toolCall.preview.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(WangsaRadius.sm),
        onTap: hasPreview ? () => setState(() => _expanded = !_expanded) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    _label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    widget.toolCall.status == 'failed'
                        ? ChatIcons.error
                        : ChatIcons.success,
                    size: 14,
                    color: widget.toolCall.status == 'failed'
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                  if (hasPreview) ...[
                    const SizedBox(width: 2),
                    Icon(
                      _expanded ? ChatIcons.collapse : ChatIcons.expand,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
              if (_expanded && hasPreview)
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 5, bottom: 4),
                  child: SelectableText(
                    widget.toolCall.preview,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
