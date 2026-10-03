import 'package:flutter/material.dart';
import 'product_models.dart';
import 'product_api.dart';

const productButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(48, 48)),
);

class ProductBody extends StatelessWidget {
  final List<Widget> children;
  const ProductBody({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        children: children,
      ),
    ),
  );
}

class ProductError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ProductError(this.message, {super.key, this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
          semanticsLabel: 'Perhatian. $message',
        ),
        if (onRetry != null)
          TextButton.icon(
            style: productButtonStyle,
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Coba lagi'),
          ),
      ],
    ),
  );
}

class JobStatus extends StatelessWidget {
  final ProductJob job;
  const JobStatus(this.job, {super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (job.status) {
      'completed' => Icons.check_circle_outline,
      'failed' => Icons.error_outline,
      'needs_input' => Icons.chat_bubble_outline,
      'awaiting_approval' => Icons.fact_check_outlined,
      'cancelled' => Icons.cancel_outlined,
      'running' => Icons.work_outline,
      _ => Icons.schedule,
    };
    final color = job.status == 'failed'
        ? scheme.error
        : job.isActive
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            job.statusLabel,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

String readableDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '';
  return '${date.day}/${date.month}/${date.year} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String productErrorMessage(Object error) => error is ProductApiException
    ? error.message
    : 'Permintaan belum berhasil. Coba lagi.';
