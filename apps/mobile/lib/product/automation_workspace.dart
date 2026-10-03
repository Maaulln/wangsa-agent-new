import 'dart:async';

import 'package:flutter/material.dart';

import 'product_api.dart';
import 'product_models.dart';
import 'product_session.dart';

class AutomationWorkspace extends StatefulWidget {
  final ProductSession session;
  const AutomationWorkspace({super.key, required this.session});

  @override
  State<AutomationWorkspace> createState() => _AutomationWorkspaceState();
}

class _AutomationWorkspaceState extends State<AutomationWorkspace> {
  final _title = TextEditingController();
  final _goal = TextEditingController();
  ProductJob? _job;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _goal.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final goal = _goal.text.trim();
    if (goal.isEmpty) {
      setState(() => _error = 'Tulis tujuan automation dulu.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final job = await widget.session.run(
        () => widget.session.api.createJob(
          _title.text.trim(),
          goal,
          newRequestKey(),
          approvalRequired: true,
        ),
      );
      if (mounted) setState(() => _job = job);
    } on ProductApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automation'),
        leading: const BackButton(),
        actions: [
          IconButton(
            tooltip: 'Library',
            icon: const Icon(Icons.library_books_outlined),
            onPressed: () {},
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Buat automation', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Jelaskan hasil yang kamu mau. Wangsa akan menyusun langkah, meminta persetujuan, lalu menjalankannya.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Nama automation',
              hintText: 'Contoh: Cek logbook PENS',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _goal,
            minLines: 6,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'Apa yang harus dilakukan agent?',
              hintText: 'Contoh: Buka halaman login PENS dan cek judul halaman. Jangan submit.',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          if (_job == null)
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.auto_awesome),
              label: Text(_busy ? 'Menyusun...' : 'Susun automation'),
            )
          else ...[
            _JobSummary(job: _job!),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => setState(() => _job = null),
              icon: const Icon(Icons.add),
              label: const Text('Buat automation lain'),
            ),
          ],
        ],
      ),
    );
  }
}

class _JobSummary extends StatelessWidget {
  final ProductJob job;
  const _JobSummary({required this.job});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(job.title.isEmpty ? 'Automation baru' : job.title),
          const SizedBox(height: 8),
          Text('Status: ${job.statusLabel}'),
          if (job.question?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(job.question!),
          ],
          if (job.error?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(job.error!),
          ],
        ],
      ),
    ),
  );
}
