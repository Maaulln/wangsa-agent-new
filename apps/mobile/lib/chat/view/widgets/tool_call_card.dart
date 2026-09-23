import 'package:flutter/material.dart';

import '../../../api/models.dart';

/// Kartu visual untuk mengekspos pemanggilan alat (tool execution) oleh AI.
class ToolCallCard extends StatefulWidget {
  final ToolCallInfo toolCall;

  const ToolCallCard({
    super.key,
    required this.toolCall,
  });

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  IconData _iconForTool(String tool) {
    final lower = tool.toLowerCase();
    if (lower.contains('search') || lower.contains('web')) return Icons.search;
    if (lower.contains('file') || lower.contains('read') || lower.contains('write')) return Icons.description_outlined;
    if (lower.contains('terminal') || lower.contains('command') || lower.contains('bash') || lower.contains('exec')) return Icons.terminal;
    if (lower.contains('image') || lower.contains('photo') || lower.contains('draw')) return Icons.image_outlined;
    if (lower.contains('code') || lower.contains('python')) return Icons.code;
    return Icons.build_circle_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPreview = widget.toolCall.preview.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: hasPreview ? () => setState(() => _expanded = !_expanded) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _iconForTool(widget.toolCall.tool),
                      size: 15,
                      color: scheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Menjalankan ${widget.toolCall.tool}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 11,
                            color: scheme.tertiary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'Selesai',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              color: scheme.onTertiaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (hasPreview) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                if (_expanded && hasPreview) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SelectableText(
                      widget.toolCall.preview,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
