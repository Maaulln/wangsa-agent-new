import 'package:flutter/material.dart';
import '../../../theme/wangsa_theme.dart';

import '../chat_icons.dart';

/// Widget pengungkapan penalaran (Reasoning / Thought Collapsible Disclosure).
/// Menampilkan proses berpikir AI secara ringkas dan rapi tanpa mendominasi tampilan balasan.
class ReasoningDisclosure extends StatefulWidget {
  final String thought;

  const ReasoningDisclosure({super.key, required this.thought});

  @override
  State<ReasoningDisclosure> createState() => _ReasoningDisclosureState();
}

class _ReasoningDisclosureState extends State<ReasoningDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.thought.trim().isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wordCount = widget.thought.trim().split(RegExp(r'\s+')).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(WangsaRadius.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(WangsaRadius.sm),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(WangsaRadius.sm),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(ChatIcons.reasoning, size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Proses Penalaran ($wordCount kata)',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? ChatIcons.collapse : ChatIcons.expand,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(WangsaRadius.xs),
                      border: Border(
                        left: BorderSide(
                          color: scheme.primary.withValues(alpha: 0.6),
                          width: 3,
                        ),
                      ),
                    ),
                    child: SelectableText(
                      widget.thought.trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.8),
                        fontStyle: FontStyle.italic,
                        height: 1.4,
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
