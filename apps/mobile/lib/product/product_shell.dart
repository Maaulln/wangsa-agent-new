import 'dart:async';

import 'package:flutter/material.dart';

import 'product_job_form.dart';
import 'product_job_page.dart';
import 'product_skill_page.dart';
import 'product_models.dart';
import 'product_provider_page.dart';
import 'product_session.dart';
import 'product_widgets.dart';

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
  int _tab = 0;
  Timer? _timer;

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

  Future<void> _newJob([ProductSkill? skill]) async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ProductJobForm(session: widget.session, skill: skill),
      ),
    );
    if (!mounted) return;
    unawaited(_refresh());
    if (id != null) await _openJob(id);
  }

  Future<void> _openJob(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductJobPage(
          session: widget.session,
          jobId: id,
          pollInterval: widget.pollInterval,
        ),
      ),
    );
    if (mounted) unawaited(_refresh());
  }

  Future<void> _openSkill(ProductSkill skill) async {
    final reuse = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductSkillPage(session: widget.session, skill: skill),
      ),
    );
    if (!mounted) return;
    unawaited(_refresh());
    if (reuse == true) await _newJob(skill);
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.session.provider;
    return Scaffold(
      appBar: AppBar(
        title: Text(['Pekerjaan', 'Prosedur', 'Akun'][_tab]),
        actions: [
          if (_tab != 2)
            IconButton(
              tooltip: 'Perbarui',
              onPressed: () => unawaited(_refresh(force: true)),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: 'Pekerjaan',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmark_outline),
            selectedIcon: Icon(Icons.bookmark),
            label: 'Prosedur',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Akun',
          ),
        ],
      ),
      body: SafeArea(
        child: _tab == 2
            ? _account()
            : RefreshIndicator(
                onRefresh: () => _refresh(force: true),
                child: ProductBody(
                  children: [
                    if (_tab == 0) ...[
                      Text(
                        'Apa yang ingin kamu selesaikan?',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Pekerjaan tetap berjalan di server saat aplikasi ditutup. Kembali ke sini untuk melihat hasilnya.',
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: productButtonStyle,
                        onPressed: provider?.configured == true
                            ? () => unawaited(_newJob())
                            : () => _openProviderSettings(),
                        icon: const Icon(Icons.add),
                        label: const Text('Buat pekerjaan'),
                      ),
                    ] else ...[
                      Text(
                        'Langkah yang bisa dipakai lagi',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Wangsa menyimpan prosedur sebagai draft. Periksa langkahnya sebelum mengaktifkan dan memakainya kembali.',
                      ),
                    ],
                    if (_error != null)
                      ProductError(
                        _error!,
                        onRetry: () => unawaited(_refresh(force: true)),
                      ),
                    const SizedBox(height: 28),
                    if (_loading)
                      const Center(child: CircularProgressIndicator())
                    else if (_tab == 0 && _jobs.isEmpty)
                      if (provider?.configured == true)
                        const Text(
                          'Belum ada pekerjaan. Mulai dengan kebutuhan yang jelas dan hasil yang kamu harapkan.',
                        )
                      else
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Akunmu siap digunakan'),
                                const SizedBox(height: 8),
                                const Text(
                                  'Hubungkan provider AI pilihanmu kapan saja untuk mulai membuat pekerjaan.',
                                ),
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed: _openProviderSettings,
                                  icon: const Icon(Icons.key_outlined),
                                  label: const Text('Atur provider AI'),
                                ),
                              ],
                            ),
                          ),
                        )
                    else if (_tab == 1 && _skills.isEmpty)
                      const Text(
                        'Belum ada prosedur. Prosedur akan muncul setelah Wangsa menyelesaikan pekerjaan yang bisa diulang.',
                      )
                    else if (_tab == 0) ...[
                      for (final job in _jobs) ...[
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                          title: Text(
                            job.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                JobStatus(job),
                                const SizedBox(height: 8),
                                Text(readableDate(job.updatedAt)),
                              ],
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => unawaited(_openJob(job.id)),
                        ),
                        const Divider(),
                      ],
                    ] else ...[
                      for (final skill in _skills) ...[
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                          title: Text(skill.name),
                          subtitle: Text(
                            '${skill.status == 'active' ? 'Aktif' : 'Draft · perlu ditinjau'}\n${skill.description}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => unawaited(_openSkill(skill)),
                        ),
                        const Divider(),
                      ],
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Future<void> _openProviderSettings() async {
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

  Widget _account() => ProductBody(
    children: [
      Text(
        widget.session.user?.username ?? '',
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
          widget.session.provider?.configured == true
              ? '${widget.session.provider?.provider}\n${widget.session.provider?.model}'
              : 'Belum diatur · opsional, bisa ditambahkan kapan saja',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _openProviderSettings,
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
            await widget.session.run(widget.session.api.deleteProvider);
            await widget.session.refreshProvider();
            if (mounted) setState(() {});
          } catch (error) {
            if (mounted) {
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
        onPressed: () => unawaited(widget.session.signOut()),
        child: const Text('Keluar dari akun'),
      ),
    ],
  );
}
