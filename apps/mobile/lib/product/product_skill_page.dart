import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'product_models.dart';
import 'product_session.dart';
import 'product_widgets.dart';

class ProductSkillPage extends StatefulWidget {
  final ProductSession session;
  final ProductSkill skill;
  const ProductSkillPage({
    super.key,
    required this.session,
    required this.skill,
  });
  @override
  State<ProductSkillPage> createState() => _ProductSkillPageState();
}

class _ProductSkillPageState extends State<ProductSkillPage> {
  bool _reviewed = false;
  bool _busy = false;
  bool _activated = false;
  String? _error;
  Future<void> _activate() async {
    if (_busy || !_reviewed) return;
    setState(() => _busy = true);
    try {
      await widget.session.run(
        () => widget.session.api.activate(widget.skill.id),
      );
      if (mounted) setState(() => _activated = true);
    } catch (error) {
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _activated || widget.skill.status == 'active';
    return Scaffold(
      appBar: AppBar(title: const Text('Tinjau prosedur')),
      body: SafeArea(
        child: ProductBody(
          children: [
            Text(
              widget.skill.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Versi ${widget.skill.version} · ${active ? 'Aktif' : 'Draft'}',
            ),
            const SizedBox(height: 12),
            Text(widget.skill.description),
            const SizedBox(height: 24),
            MarkdownBody(data: widget.skill.content, selectable: true),
            const SizedBox(height: 24),
            if (_error != null) ProductError(_error!),
            if (!active) ...[
              const Text(
                'Periksa prasyarat, langkah, dan cara verifikasinya. Aktivasi bukan jaminan bahwa prosedur sesuai untuk semua pekerjaan.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Saya sudah meninjau prosedur ini.'),
                value: _reviewed,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _reviewed = value ?? false),
              ),
              FilledButton(
                style: productButtonStyle,
                onPressed: _reviewed && !_busy ? _activate : null,
                child: Text(_busy ? 'Mengaktifkan…' : 'Aktifkan prosedur'),
              ),
            ] else
              FilledButton.icon(
                style: productButtonStyle,
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.add),
                label: const Text('Gunakan untuk pekerjaan baru'),
              ),
          ],
        ),
      ),
    );
  }
}
