import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../voice/speech_engine.dart';
import 'product_api.dart';
import 'product_job_form.dart';
import 'product_skill_page.dart';
import 'product_models.dart';
import 'product_provider_page.dart';
import 'product_session.dart';
import 'product_widgets.dart';

/// Shell utama mode produk, bergaya ChatGPT/Telegram: sidebar berisi riwayat
/// pekerjaan (seperti riwayat obrolan) dan menukar thread yang tampil di
/// panel utama TANPA berpindah halaman. Pembuatan workflow (judul + prompt +
/// kredensial situs) tetap sebuah halaman terpisah, dibuka dari tombol
/// "Workflow baru" di sidebar.
class ProductShell extends StatefulWidget {
  final ProductSession session;
  final Duration pollInterval;
  const ProductShell({
    super.key,
    required this.session,
    required this.pollInterval,
  });
  @override
  State<ProductShell> createState() => _ProductShellState();
}

class _ProductShellState extends State<ProductShell>
    with WidgetsBindingObserver {
  List<ProductJob> _jobs = [];
  List<ProductSkill> _skills = [];
  bool _loading = true;
  bool _fetching = false;
  bool _refreshQueued = false;
  String? _error;
  Timer? _timer;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Job yang sedang ditampilkan di panel utama. null berarti "halaman
  /// utama" (layar sapaan + composer cepat), persis home ChatGPT sebelum
  /// obrolan pertama dipilih/dibuat.
  String? _selectedJobId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _startPolling();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      unawaited(_refresh());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    if (_fetching) {
      // Polling can already be in flight when the user asks for a refresh.
      // Preserve that explicit request so it runs after the current snapshot.
      if (force) _refreshQueued = true;
      return;
    }
    _fetching = true;
    try {
      if (widget.session.provider == null) {
        await widget.session.refreshProvider();
      }
      final jobs = await widget.session.run(widget.session.api.jobs);
      final skills = await widget.session.run(widget.session.api.skills);
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _skills = skills;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      _fetching = false;
      if (mounted) setState(() => _loading = false);
      if (_refreshQueued && mounted) {
        _refreshQueued = false;
        unawaited(_refresh(force: true));
      }
    }
  }

  void _closeDrawerIfOpen() {
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.of(context).pop();
    }
  }

  void _selectJob(String? id) {
    _closeDrawerIfOpen();
    setState(() => _selectedJobId = id);
  }

  Future<void> _openWorkflowForm([ProductSkill? skill]) async {
    _closeDrawerIfOpen();
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ProductJobForm(session: widget.session, skill: skill),
      ),
    );
    if (!mounted) return;
    unawaited(_refresh());
    if (id != null) _selectJob(id);
  }

  Future<void> _openSkill(ProductSkill skill) async {
    _closeDrawerIfOpen();
    final reuse = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductSkillPage(session: widget.session, skill: skill),
      ),
    );
    if (!mounted) return;
    unawaited(_refresh());
    if (reuse == true) await _openWorkflowForm(skill);
  }

  Future<void> _openAccount() async {
    _closeDrawerIfOpen();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductAccountPage(session: widget.session),
      ),
    );
    if (mounted) {
      setState(() {});
      unawaited(_refresh());
    }
  }

  Future<void> _openProviderSettings() async {
    _closeDrawerIfOpen();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductProviderPage(session: widget.session),
      ),
    );
    if (mounted) {
      setState(() {});
      unawaited(_refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedId = _selectedJobId;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('Wangsa'),
        leading: selectedId == null
            ? null
            : IconButton(
                tooltip: 'Pekerjaan baru',
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: () => _selectJob(null),
              ),
        actions: [
          IconButton(
            tooltip: 'Perbarui',
            onPressed: () => unawaited(_refresh(force: true)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      drawer: _ProductDrawer(
        jobs: _jobs,
        skills: _skills,
        loading: _loading,
        selectedJobId: selectedId,
        username: widget.session.user?.username ?? '',
        onNewChat: () => _selectJob(null),
        onNewWorkflow: () => unawaited(_openWorkflowForm()),
        onOpenJob: (job) => _selectJob(job.id),
        onOpenSkill: (skill) => unawaited(_openSkill(skill)),
        onOpenAccount: () => unawaited(_openAccount()),
      ),
      body: SafeArea(
        child: selectedId == null
            ? _HomeComposer(
                error: _error,
                providerConfigured:
                    widget.session.provider?.configured == true,
                onConfigureProvider: () =>
                    unawaited(_openProviderSettings()),
                onSend: (text) async {
                  final job = await widget.session.run(
                    () => widget.session.api.createJob(
                      '',
                      text,
                      newRequestKey(),
                    ),
                  );
                  if (!mounted) return;
                  _selectJob(job.id);
                  unawaited(_refresh());
                },
              )
            : _JobThreadView(
                key: ValueKey(selectedId),
                session: widget.session,
                jobId: selectedId,
                pollInterval: widget.pollInterval,
                onOpenSkill: (skill) => unawaited(_openSkill(skill)),
                onOpenProviderSettings: () =>
                    unawaited(_openProviderSettings()),
                onRetryWithWorkflow: (job) =>
                    unawaited(_openWorkflowFormRetry(job)),
              ),
      ),
    );
  }

  Future<void> _openWorkflowFormRetry(ProductJob job) async {
    _closeDrawerIfOpen();
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ProductJobForm(
          session: widget.session,
          initialTitle: job.title,
          initialPrompt: job.prompt,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(_refresh());
    if (id != null) _selectJob(id);
  }
}

/// Layar sapaan di panel utama ketika belum ada obrolan/pekerjaan terpilih —
/// persis home ChatGPT: judul + kotak input di tengah/bawah untuk langsung
/// mulai. Ini jalur ringan (tanpa judul/kredensial situs); untuk itu pakai
/// "Workflow baru" di sidebar.
class _HomeComposer extends StatefulWidget {
  final String? error;
  final bool providerConfigured;
  final VoidCallback onConfigureProvider;
  final Future<void> Function(String text) onSend;
  const _HomeComposer({
    required this.error,
    required this.providerConfigured,
    required this.onConfigureProvider,
    required this.onSend,
  });

  @override
  State<_HomeComposer> createState() => _HomeComposerState();
}

class _HomeComposerState extends State<_HomeComposer> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  // Dikte suara di komposer memakai mesin bawaan perangkat (speech_to_text),
  // sama seperti dikte di mode chat lama — tapi lewat DeviceSpeechEngine,
  // bukan BackendSpeechEngine, karena STT backend cuma ada di legacy
  // gateway (port 9901) dan mode produk tidak menyalakannya.
  late final SpeechEngine _speechEngine = DeviceSpeechEngine();
  bool _listening = false;
  String? _voiceError;

  @override
  void dispose() {
    if (_listening) unawaited(_speechEngine.cancel());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSend(text);
      _controller.clear();
    } catch (error) {
      if (mounted) setState(() => _error = productErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleListening() async {
    if (_busy) return;
    if (_listening) {
      await _speechEngine.cancel();
      if (mounted) setState(() => _listening = false);
      return;
    }
    setState(() {
      _listening = true;
      _voiceError = null;
    });
    final baseText = _controller.text;
    final prefix = baseText.isEmpty || baseText.endsWith(' ')
        ? baseText
        : '$baseText ';
    await _speechEngine.listen(
      onPartial: (text) {
        if (!mounted) return;
        _controller.text = '$prefix$text';
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      },
      onFinal: (text) {
        if (!mounted) return;
        setState(() {
          _controller.text = text.isEmpty ? baseText : '$prefix$text';
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
          _listening = false;
        });
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _voiceError = message;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Apa yang ingin kamu selesaikan?',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Ketik kebutuhanmu di bawah untuk memulai, atau buka '
                      '"Workflow baru" di menu kiri untuk pekerjaan dengan '
                      'kredensial situs.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (!widget.providerConfigured) ...[
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: widget.onConfigureProvider,
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Atur provider AI dulu'),
                      ),
                    ],
                    if (widget.error != null) ProductError(widget.error!),
                    if (_error != null) ProductError(_error!),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(28),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _controller,
                        enabled: !_busy,
                        minLines: 1,
                        maxLines: 6,
                        maxLength: 16000,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'Kirim pesan…',
                          border: InputBorder.none,
                          counterText: '',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                      ),
                      if (_voiceError != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, bottom: 4),
                          child: Text(
                            _voiceError!,
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          // Lampiran belum tersedia — backend belum punya
                          // endpoint upload untuk mode produk. Tombol tetap
                          // tampil (konsisten dengan komposer ala ChatGPT)
                          // tapi nonaktif sampai API-nya ada.
                          IconButton(
                            tooltip: 'Lampirkan (segera hadir)',
                            onPressed: null,
                            icon: const Icon(Icons.add),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: _listening
                                ? 'Berhenti mendengarkan'
                                : 'Dikte suara',
                            onPressed: _busy ? null : _toggleListening,
                            icon: Icon(
                              _listening ? Icons.mic : Icons.mic_none,
                              color: _listening
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton.filled(
                            onPressed: _busy ? null : _submit,
                            icon: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Panel thread untuk satu pekerjaan, ditanam langsung di body ProductShell
/// (bukan halaman terpisah) — persis cara ChatGPT menukar isi panel kanan
/// saat item riwayat di sidebar diklik. Diberi `key: ValueKey(jobId)` oleh
/// pemanggil supaya widget dibangun ulang bersih setiap ganti thread.
class _JobThreadView extends StatefulWidget {
  final ProductSession session;
  final String jobId;
  final Duration pollInterval;
  final ValueChanged<ProductSkill> onOpenSkill;
  final VoidCallback onOpenProviderSettings;
  final ValueChanged<ProductJob> onRetryWithWorkflow;
  const _JobThreadView({
    super.key,
    required this.session,
    required this.jobId,
    required this.pollInterval,
    required this.onOpenSkill,
    required this.onOpenProviderSettings,
    required this.onRetryWithWorkflow,
  });

  @override
  State<_JobThreadView> createState() => _JobThreadViewState();
}

class _JobThreadViewState extends State<_JobThreadView> {
  ProductJob? _job;
  String? _error;
  bool _fetching = false;
  bool _refreshQueued = false;
  bool _busy = false;
  Timer? _timer;
  final _reply = TextEditingController();
  Map<String, dynamic>? _pendingReply;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _timer?.cancel();
    _reply.dispose();
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
      if (mounted) {
        setState(() {
          _job = job;
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
    return RefreshIndicator(
      onRefresh: () => _refresh(force: true),
      child: ProductBody(
        children: [
          if (_error != null)
            ProductError(_error!, onRetry: () => unawaited(_refresh(force: true))),
          if (job == null && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (job != null) ...[
            Text(job.title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            JobStatus(job),
            const SizedBox(height: 24),
            SelectableText(job.prompt),
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
                onPressed: widget.onOpenProviderSettings,
                icon: const Icon(Icons.tune),
                label: const Text('Atur provider AI'),
              ),
              FilledButton.icon(
                style: productButtonStyle,
                onPressed: () => widget.onRetryWithWorkflow(job),
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
                      if (matches.isEmpty) return;
                      widget.onOpenSkill(matches.first);
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
    );
  }
}

/// Sidebar ala ChatGPT/Telegram: "Pekerjaan baru" (thread kosong) dan
/// "Workflow baru" (form lengkap) di atas, riwayat pekerjaan di tengah,
/// prosedur, lalu akun tertambat di bawah.
class _ProductDrawer extends StatelessWidget {
  final List<ProductJob> jobs;
  final List<ProductSkill> skills;
  final bool loading;
  final String? selectedJobId;
  final String username;
  final VoidCallback onNewChat;
  final VoidCallback onNewWorkflow;
  final ValueChanged<ProductJob> onOpenJob;
  final ValueChanged<ProductSkill> onOpenSkill;
  final VoidCallback onOpenAccount;

  const _ProductDrawer({
    required this.jobs,
    required this.skills,
    required this.loading,
    required this.selectedJobId,
    required this.username,
    required this.onNewChat,
    required this.onNewWorkflow,
    required this.onOpenJob,
    required this.onOpenSkill,
    required this.onOpenAccount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Wangsa', style: theme.textTheme.titleLarge),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onPressed: onNewChat,
                      icon: const Icon(Icons.add_comment_outlined),
                      label: const Text('Pekerjaan baru'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onPressed: onNewWorkflow,
                      icon: const Icon(Icons.account_tree_outlined),
                      label: const Text('Workflow baru'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  _SectionLabel('Riwayat'),
                  if (jobs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Text(
                        'Belum ada pekerjaan.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    for (final job in jobs)
                      ListTile(
                        dense: true,
                        selected: job.id == selectedJobId,
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: Text(
                          job.title.isEmpty ? job.prompt : job.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          readableDate(job.updatedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => onOpenJob(job),
                      ),
                  const Divider(),
                  _SectionLabel('Prosedur'),
                  if (skills.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Text(
                        'Belum ada prosedur.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    for (final skill in skills)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          skill.status == 'active'
                              ? Icons.bookmark
                              : Icons.bookmark_outline,
                        ),
                        title: Text(
                          skill.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          skill.status == 'active' ? 'Aktif' : 'Draft',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => onOpenSkill(skill),
                      ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(
                username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('Akun & provider AI'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenAccount,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

/// Halaman akun terpisah, diakses lewat sidebar.
class ProductAccountPage extends StatelessWidget {
  final ProductSession session;
  const ProductAccountPage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Akun')),
      body: SafeArea(
        child: ProductBody(
          children: [
            Text(
              session.user?.username ?? '',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Kunci API digunakan hanya untuk pekerjaan akunmu. Penggunaan model ditagihkan oleh provider.',
            ),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.key_outlined),
              title: const Text('Provider AI'),
              subtitle: Text(
                session.provider?.configured == true
                    ? '${session.provider?.provider}\n${session.provider?.model}'
                    : 'Belum diatur · opsional, bisa ditambahkan kapan saja',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ProductProviderPage(session: session),
                  ),
                );
              },
            ),
            const Divider(),
            const SizedBox(height: 20),
            OutlinedButton(
              style: productButtonStyle,
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Putuskan provider?'),
                    content: const Text(
                      'Pekerjaan aktif akan dibatalkan. Hubungkan provider lagi sebelum membuat pekerjaan baru.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Kembali'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Putuskan'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                try {
                  await session.run(session.api.deleteProvider);
                  await session.refreshProvider();
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(productErrorMessage(error))),
                    );
                  }
                }
              },
              child: const Text('Putuskan provider'),
            ),
            const SizedBox(height: 12),
            TextButton(
              style: productButtonStyle,
              onPressed: () => unawaited(session.signOut()),
              child: const Text('Keluar dari akun'),
            ),
          ],
        ),
      ),
    );
  }
}
