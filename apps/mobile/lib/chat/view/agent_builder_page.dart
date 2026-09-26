import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/chat_bloc.dart';

/// A focused brief workspace that hands the request to Wangsa's configured
/// assistant. Publishing a real agent needs a blueprint API that the mobile
/// gateway does not currently expose, so the result is explicitly a design
/// conversation rather than a published agent.
class AgentBuilderPage extends StatefulWidget {
  const AgentBuilderPage({super.key});

  @override
  State<AgentBuilderPage> createState() => _AgentBuilderPageState();
}

class _AgentBuilderPageState extends State<AgentBuilderPage> {
  final _name = TextEditingController();
  final _purpose = TextEditingController();
  final _tasks = TextEditingController();
  final _guardrails = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _purpose.dispose();
    _tasks.dispose();
    _guardrails.dispose();
    super.dispose();
  }

  void _submit() {
    if (_busy || _purpose.text.trim().isEmpty) return;
    final brief =
        '''Bantu saya merancang agent. Buat rancangan yang bisa ditinjau, jangan mengklaim agent sudah dibuat atau dipublikasikan.

Nama sementara: ${_name.text.trim().isEmpty ? 'Belum ditentukan' : _name.text.trim()}
Tujuan utama: ${_purpose.text.trim()}
Pekerjaan yang perlu dilakukan: ${_tasks.text.trim().isEmpty ? 'Usulkan berdasarkan tujuan' : _tasks.text.trim()}
Batasan dan persetujuan: ${_guardrails.text.trim().isEmpty ? 'Tandai asumsi dan minta persetujuan untuk tindakan yang berdampak' : _guardrails.text.trim()}

Susun ringkasan peran, alur kerja, kemampuan yang diperlukan, batas keamanan, dan pertanyaan klarifikasi. Bedakan hal yang sudah diputuskan dari asumsi.''';
    context.read<ChatBloc>().add(AgentBuildRequested(brief));
    setState(() => _busy = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Bangun Agent')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              'Mulai dari hasil yang kamu inginkan.',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              'Ceritakan peran dan batas agent. Wangsa akan membuka percakapan baru untuk menyusun rancangan yang bisa kamu tinjau.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Nama agent (opsional)',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _purpose,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Apa tujuan utamanya?',
                hintText: 'Contoh: membantu tim menyiapkan laporan mingguan',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tasks,
              minLines: 2,
              maxLines: 5,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Pekerjaan yang perlu dilakukan',
                hintText:
                    'Sumber yang dibaca, langkah, dan hasil yang diharapkan',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _guardrails,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Batas dan persetujuan',
                hintText:
                    'Tindakan yang harus meminta izin atau tidak boleh dilakukan',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Rancangan akan dibahas di chat. Pembuatan Blueprint, persetujuan, dan publikasi agent belum tersedia lewat API mobile.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: !_busy && _purpose.text.trim().isNotEmpty
                  ? _submit
                  : null,
              icon: const Icon(Icons.arrow_upward_rounded),
              label: const Text('Susun rancangan di chat'),
            ),
          ],
        ),
      ),
    );
  }
}
