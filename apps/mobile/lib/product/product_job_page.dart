import 'dart:async';
import 'package:flutter/material.dart';
import 'product_api.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'product_job_form.dart';
import 'product_skill_page.dart';
import 'product_models.dart';
import 'product_provider_page.dart';
import 'product_session.dart';
import 'product_widgets.dart';

class ProductJobPage extends StatefulWidget {
  final ProductSession session;
  final String jobId;
  final Duration pollInterval;
  const ProductJobPage({
    super.key,
    required this.session,
    required this.jobId,
    required this.pollInterval,
  });
  @override
  State<ProductJobPage> createState() => _ProductJobPageState();
}

class _ProductJobPageState extends State<ProductJobPage>
    with WidgetsBindingObserver {
  ProductJob? _job;
  String? _error;
  bool _fetching = false;
  bool _refreshQueued = false;
  bool _busy = false;
  ProductBlueprint? _blueprint;
  Timer? _timer;
  final _reply = TextEditingController();
  Map<String, dynamic>? _pendingReply;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _poll();
    unawaited(_restoreReply());
  }

  Future<void> _restoreReply() async {
    final pending = await widget.session.pendingReply(widget.jobId);
    if (mounted && pending != null) {
      setState(() {
        _pendingReply = pending;
        _reply.text = pending['message'] as String;
      });
    }
  }

  void _poll() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _poll();
      unawaited(_refresh());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reply.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    if (_fetching) {
      if (force) _refreshQueued = true;
      return;
    }
    _fetching = true;
    try {
      final job = await widget.session.run(
        () => widget.session.api.job(widget.jobId),
      );
      ProductBlueprint? blueprint;
      if (job.status == 'awaiting_approval' || job.status == 'queued') {
        blueprint = await widget.session.run(
          () => widget.session.api.blueprint(widget.jobId),
        );
      }
      if (mounted) {
        setState(() {
          _job = job;
          _blueprint = blueprint;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      _fetching = false;
      if (_refreshQueued && mounted) {
        _refreshQueued = false;
        unawaited(_refresh(force: true));
      }
    }
  }

  Future<void> _sendReply() async {
    if (_busy || _reply.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _pendingReply ??= {'message': _reply.text.trim(), 'key': newRequestKey()};
      await widget.session.savePendingReply(widget.jobId, _pendingReply!);
      final job = await widget.session.run(
        () => widget.session.api.reply(
          widget.jobId,
          _pendingReply!['message'] as String,
          _pendingReply!['key'] as String,
        ),
      );
      await widget.session.clearPendingReply(widget.jobId);
      if (mounted) {
        setState(() {
          _job = job;
          _reply.clear();
          _pendingReply = null;
        });
      }
    } catch (error) {
      if (error is ProductApiException && !error.uncertain) {
        await widget.session.clearPendingReply(widget.jobId);
        _pendingReply = null;
      }
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final blueprint = _blueprint;
    if (_busy || blueprint == null || blueprint.hash.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final job = await widget.session.run(() => widget.session.api.approve(widget.jobId, blueprint.hash, newRequestKey()));
      if (mounted) setState(() => _job = job);
    } catch (error) {
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProviderSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductProviderPage(session: widget.session),
      ),
    );
  }

  Future<void> _createAnotherAttempt(ProductJob job) async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ProductJobForm(
          session: widget.session,
          initialTitle: job.title,
          initialPrompt: job.prompt,
        ),
      ),
    );
    if (!mounted || id == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductJobPage(
          session: widget.session,
          jobId: id,
          pollInterval: widget.pollInterval,
        ),
      ),
    );
  }

  Future<void> _cancel() async {
    if (_busy) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Batalkan pekerjaan?'),
        content: const Text(
          'Tindakan yang sudah dilakukan agent tidak otomatis dibatalkan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Lanjutkan'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Batalkan pekerjaan'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final job = await widget.session.run(
        () => widget.session.api.cancel(widget.jobId),
      );
      if (mounted) setState(() => _job = job);
    } catch (error) {
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detail pekerjaan'),
        actions: [
          IconButton(
            tooltip: 'Perbarui',
            onPressed: () => unawaited(_refresh(force: true)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ProductBody(
          children: [
            if (_error != null)
              ProductError(
                _error!,
                onRetry: () => unawaited(_refresh(force: true)),
              ),
            if (job == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (job != null) ...[
              Text(job.title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              JobStatus(job),
              const SizedBox(height: 24),
              SelectableText(job.prompt),
              if (_blueprint != null) ...[
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Blueprint v${_blueprint!.revision}', style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text(_blueprint!.content['summary'] as String? ?? 'Rencana eksekusi'),
                        const SizedBox(height: 8),
                        SelectableText('Hash: ${_blueprint!.hash}', style: Theme.of(context).textTheme.bodySmall),
                        if (job.status == 'awaiting_approval') ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(onPressed: _busy ? null : _approve, icon: const Icon(Icons.check), label: const Text('Setujui dan jalankan')),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (job.question?.isNotEmpty == true) ...[
                const SizedBox(height: 28),
                Text(
                  'Wangsa perlu jawabanmu',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(job.question!),
                const SizedBox(height: 16),
                TextField(
                  controller: _reply,
                  enabled: !_busy && _pendingReply == null,
                  minLines: 2,
                  maxLines: 8,
                  maxLength: 16000,
                  decoration: const InputDecoration(labelText: 'Jawabanmu'),
                ),
                FilledButton(
                  style: productButtonStyle,
                  onPressed: _busy ? null : _sendReply,
                  child: Text(_busy ? 'Mengirim…' : 'Kirim jawaban'),
                ),
              ],
              if (job.error?.isNotEmpty == true) ProductError(job.error!),
              if (job.status == 'failed') ...[
                const SizedBox(height: 12),
                const Text(
                  'Pekerjaan yang berhenti tidak dapat dilanjutkan. Perbaiki provider atau model, lalu buat pekerjaan baru. Kredensial situs perlu dimasukkan kembali.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: productButtonStyle,
                  onPressed: _openProviderSettings,
                  icon: const Icon(Icons.tune),
                  label: const Text('Atur provider AI'),
                ),
                FilledButton.icon(
                  style: productButtonStyle,
                  onPressed: () => unawaited(_createAnotherAttempt(job)),
                  icon: const Icon(Icons.replay),
                  label: const Text('Buat ulang pekerjaan'),
                ),
              ],
              if (job.report?.isNotEmpty == true) ...[
                const SizedBox(height: 28),
                Text(
                  'Hasil pekerjaan',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                MarkdownBody(data: job.report!, selectable: true),
              ],
              if (job.skillId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: TextButton.icon(
                    style: productButtonStyle,
                    icon: const Icon(Icons.bookmark_outline),
                    label: const Text('Tinjau prosedur dari pekerjaan ini'),
                    onPressed: () async {
                      try {
                        final skills = await widget.session.run(
                          widget.session.api.skills,
                        );
                        final matches = skills.where(
                          (skill) => skill.id == job.skillId,
                        );
                        if (!context.mounted || matches.isEmpty) return;
                        await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => ProductSkillPage(
                              session: widget.session,
                              skill: matches.first,
                            ),
                          ),
                        );
                      } catch (error) {
                        if (mounted) {
                          setState(() => _error = productErrorMessage(error));
                        }
                      }
                    },
                  ),
                ),
              const SizedBox(height: 28),
              Text('Aktivitas', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final event in job.events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(event.message),
                      Text(
                        readableDate(event.createdAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              if (job.isActive)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: OutlinedButton(
                    style: productButtonStyle,
                    onPressed: _busy ? null : _cancel,
                    child: const Text('Batalkan pekerjaan'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
