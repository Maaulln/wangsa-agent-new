import 'package:flutter/material.dart';
import '../../../theme/wangsa_theme.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api/models.dart';
import '../chat_icons.dart';

class _Source {
  final String label;
  final Uri uri;

  const _Source(this.label, this.uri);
}

/// Menampilkan tautan Markdown dari jawaban sebagai sumber yang ringkas.
class SourceChips extends StatelessWidget {
  final List<ReplySource> sources;
  final String response;

  const SourceChips({
    super.key,
    this.sources = const [],
    required this.response,
  });

  static final _linkPattern = RegExp(r'\[([^\]]+)\]\((https?://[^)\s]+)\)');

  List<_Source> _sources() {
    if (sources.isNotEmpty) {
      final parsed = <_Source>[];
      for (final source in sources.take(5)) {
        final uri = Uri.tryParse(source.url);
        if (uri == null || uri.host.isEmpty) continue;
        parsed.add(
          _Source(source.title.isEmpty ? uri.host : source.title, uri),
        );
      }
      return parsed;
    }
    final seen = <String>{};
    final parsedSources = <_Source>[];
    for (final match in _linkPattern.allMatches(response)) {
      final label = match.group(1)?.trim() ?? '';
      final rawUrl = match.group(2)?.trim() ?? '';
      final uri = Uri.tryParse(rawUrl);
      if (uri == null || uri.host.isEmpty || !seen.add(uri.toString())) {
        continue;
      }
      parsedSources.add(_Source(label.isEmpty ? uri.host : label, uri));
    }
    return parsedSources.take(5).toList();
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources();
    if (sources.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sumber yang digunakan',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final source in sources)
                Semantics(
                  link: true,
                  label: 'Buka sumber ${source.label}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(WangsaRadius.pill),
                    onTap: () async {
                      try {
                        final opened = await launchUrl(
                          source.uri,
                          mode: LaunchMode.externalApplication,
                        );
                        if (!context.mounted || opened) return;
                      } catch (_) {
                        if (!context.mounted) return;
                      }
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(
                            content: Text('Tautan sumber tidak bisa dibuka.'),
                          ),
                        );
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.45,
                        ),
                        borderRadius: BorderRadius.circular(WangsaRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            ChatIcons.source,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 150),
                            child: Text(
                              source.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
