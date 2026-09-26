import 'dart:async';
import 'package:flutter/material.dart';
import 'product_api.dart';
import 'product_models.dart';
import 'product_session.dart';
import 'product_widgets.dart';

class ProductJobForm extends StatefulWidget {
  final ProductSession session;
  final ProductSkill? skill;
  final String initialTitle;
  final String initialPrompt;
  const ProductJobForm({
    super.key,
    required this.session,
    this.skill,
    this.initialTitle = '',
    this.initialPrompt = '',
  });
  @override
  State<ProductJobForm> createState() => _ProductJobFormState();
}

class _ProductJobFormState extends State<ProductJobForm> {
  final _title = TextEditingController();
  final _prompt = TextEditingController();
  final _netid = TextEditingController();
  final _password = TextEditingController();
  Map<String, dynamic>? _pending;
  bool _busy = false;
  bool _restoring = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _title.text = widget.initialTitle;
    _prompt.text = widget.initialPrompt;
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final pending = await widget.session.pending();
      if (!mounted) return;
      if (pending != null && pending['action'] == 'create') {
        _pending = pending;
        _title.text = pending['title'] as String? ?? '';
        _prompt.text = pending['prompt'] as String? ?? '';
        final secrets = Map<String, dynamic>.from(
          pending['browser_secrets'] as Map? ?? const {},
        );
        _netid.text = secrets['netid'] as String? ?? '';
        _password.text = secrets['password'] as String? ?? '';
      }
    } catch (_) {
      if (mounted) _error = 'Draft belum bisa dibuka.';
    }
    if (mounted) setState(() => _restoring = false);
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _netid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _restoring) return;
    if (_prompt.text.trim().isEmpty) {
      setState(() => _error = 'Ceritakan kebutuhanmu terlebih dahulu.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _pending ??= {
        'action': 'create',
        'key': newRequestKey(),
        'title': _title.text.trim(),
        'prompt': _prompt.text.trim(),
        'skill_id': widget.skill?.id,
        'browser_secrets': {
          if (_netid.text.trim().isNotEmpty) 'netid': _netid.text.trim(),
          if (_password.text.isNotEmpty) 'password': _password.text,
        },
      };
      // Persist before dispatch. An uncertain response retries this same request,
      // including after app restart; never mint a second paid job accidentally.
      await widget.session.savePending(_pending!);
      final job = await widget.session.run(
        () => widget.session.api.createJob(
          _pending!['title'] as String,
          _pending!['prompt'] as String,
          _pending!['key'] as String,
          skillId: _pending!['skill_id'] as String?,
          browserSecrets: Map<String, String>.from(
            _pending!['browser_secrets'] as Map? ?? const {},
          ),
        ),
      );
      await widget.session.clearPending();
      _pending = null;
      _netid.clear();
      _password.clear();
      if (mounted) Navigator.of(context).pop(job.id);
    } catch (error) {
      if (error is ProductApiException && !error.uncertain) {
        _pending = null;
        await widget.session.clearPending();
      }
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pekerjaan baru')),
    body: SafeArea(
      child: ProductBody(
        children: [
          Text(
            'Ceritakan hasil yang kamu butuhkan',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (widget.initialPrompt.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Kebutuhan dari pekerjaan sebelumnya sudah disalin. Masukkan kembali kredensial situs jika diperlukan.',
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Sertakan bahan, batasan, dan hasil yang diharapkan. Untuk tugas situs, isi kredensial di kolom terpisah; nilainya dienkripsi dan hanya dipakai selama pekerjaan.',
          ),
          if (widget.skill != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('Prosedur: ${widget.skill!.name}'),
            ),
          const SizedBox(height: 24),
          TextField(
            controller: _title,
            enabled: !_busy && !_restoring && _pending == null,
            maxLength: 120,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Judul (opsional)'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _prompt,
            enabled: !_busy && !_restoring && _pending == null,
            minLines: 6,
            maxLines: 14,
            maxLength: 16000,
            decoration: const InputDecoration(
              labelText: 'Kebutuhanmu',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _netid,
            enabled: !_busy && !_restoring && _pending == null,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: 'NetID situs (opsional)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !_busy && !_restoring && _pending == null,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(
              labelText: 'Kata sandi situs (opsional)',
            ),
          ),
          if (_pending != null)
            const Text(
              'Ada permintaan yang belum terkonfirmasi. Kirim ulang dengan isi yang sama untuk memeriksa hasilnya tanpa membuat duplikat.',
            ),
          if (_error != null) ProductError(_error!),
          const SizedBox(height: 24),
          FilledButton(
            style: productButtonStyle,
            onPressed: _busy || _restoring ? null : _submit,
            child: Text(
              _busy
                  ? 'Mengirim…'
                  : _pending != null
                  ? 'Periksa permintaan'
                  : 'Mulai pekerjaan',
            ),
          ),
        ],
      ),
    ),
  );
}
