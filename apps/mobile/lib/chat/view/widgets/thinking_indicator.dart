import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../chat_icons.dart';

/// Jejak aktivitas yang benar-benar dikirim gateway selama jawaban berjalan.
class ThinkingIndicator extends StatelessWidget {
  final ToolCallInfo? activity;
  final List<ToolCallInfo> activities;
  final bool isWaitingForReply;

  const ThinkingIndicator({
    super.key,
    this.activity,
    this.activities = const [],
    this.isWaitingForReply = false,
  });

  static String labelFor(ToolCallInfo? activity) {
    final tool = (activity?.tool ?? '').toLowerCase();
    String action;
    if (tool.contains('extract') ||
        tool.contains('browser') ||
        tool.contains('navigate')) {
      action = 'membuka halaman web';
    } else if (tool.contains('search') || tool.contains('web')) {
      action = 'mencari di web';
    } else if (tool.contains('file') ||
        tool.contains('read') ||
        tool.contains('write')) {
      action = 'membaca atau mengelola file';
    } else if (tool.contains('terminal') ||
        tool.contains('command') ||
        tool.contains('exec')) {
      action = 'menjalankan perintah';
    } else if (tool.contains('image') || tool.contains('photo')) {
      action = 'memproses gambar';
    } else if (tool.isEmpty) {
      action = 'memproses permintaan';
    } else {
      action = 'menggunakan ${activity!.tool}';
    }
    return switch (activity?.status) {
      'completed' => 'Selesai $action',
      'failed' => 'Gagal $action',
      _ => 'Sedang $action',
    };
  }

  static IconData iconFor(ToolCallInfo? activity) {
    return ChatIcons.forTool(activity?.tool ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final visibleActivities = activities.isNotEmpty
        ? activities
        : activity == null
        ? const <ToolCallInfo>[]
        : [activity!];
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    if (visibleActivities.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Semantics(
          liveRegion: true,
          label: 'Wangsa sedang memproses permintaan',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Wangsa sedang memproses…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < visibleActivities.length; i++)
            Semantics(
              liveRegion: i == visibleActivities.length - 1,
              label: labelFor(visibleActivities[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      iconFor(visibleActivities[i]),
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        labelFor(visibleActivities[i]),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (visibleActivities[i].status == 'running')
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.primary,
                        ),
                      )
                    else
                      Icon(
                        visibleActivities[i].status == 'failed'
                            ? ChatIcons.error
                            : ChatIcons.success,
                        size: 16,
                        color: visibleActivities[i].status == 'failed'
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          if (isWaitingForReply &&
              visibleActivities.every((item) => item.status != 'running'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                label: 'Wangsa sedang melanjutkan proses',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Wangsa melanjutkan proses…',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
