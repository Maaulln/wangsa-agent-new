import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../api/models.dart';
import '../user_profile_controller.dart';

/// Profil pengguna — BELUM ada sistem akun/login di Wangsa sama sekali
/// (lihat `UserProfileController`). Yang diedit di sini adalah profil
/// LOKAL di perangkat ini saja: nama panggilan dan preferensi singkat,
/// dikirim sebagai konteks ke Agent di setiap pesan (lihat
/// `ChatBloc._onMessageSubmitted`) supaya balasan AI disesuaikan tanpa
/// perlu login sama sekali.
class ProfilePage extends StatefulWidget {
  final PublicAgent? agent;
  final UserProfileController userProfile;

  const ProfilePage({super.key, required this.agent, required this.userProfile});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _nameController;
  late final TextEditingController _preferencesController;
  PackageInfo? _packageInfo;
  bool _packageInfoFailed = false;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final current = widget.userProfile.value;
    _nameController = TextEditingController(text: current.name);
    _preferencesController = TextEditingController(text: current.preferences);
    _nameController.addListener(_markDirty);
    _preferencesController.addListener(_markDirty);
    unawaited(_loadPackageInfo());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _preferencesController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _packageInfo = info);
    } catch (_) {
      // Sekadar-terbaik — kalau platform tidak bisa memberi info versi,
      // halaman tetap menunjukkan 'Tidak diketahui', bukan macet di
      // 'Memuat...' selamanya atau melempar galat ke pengguna.
      if (mounted) setState(() => _packageInfoFailed = true);
    }
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    await widget.userProfile.save(
      UserProfile(
        name: _nameController.text.trim(),
        preferences: _preferencesController.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Profil tersimpan.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final agent = widget.agent;
    final packageInfo = _packageInfo;

    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: CircleAvatar(
              radius: 40,
              backgroundColor: scheme.primaryContainer,
              child: Icon(
                Icons.person_outline,
                size: 40,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Wangsa belum punya sistem akun',
            textAlign: TextAlign.center,
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Tidak ada login — tapi kolom di bawah ini disimpan di HP ini dan '
            'dikirim sebagai konteks ke Agent supaya balasannya sesuai dengan Anda.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const Divider(height: 40),
          Text('Nama & preferensi', style: textTheme.labelMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Nama panggilan',
              hintText: 'Misal: Doni',
              prefixIcon: Icon(Icons.badge_outlined),
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _preferencesController,
            decoration: const InputDecoration(
              labelText: 'Preferensi (opsional)',
              hintText: 'Misal: santai, bahasa Indonesia, jawaban singkat',
              prefixIcon: Icon(Icons.tune_rounded),
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 3,
            minLines: 2,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_saving || !_dirty) ? null : _saveProfile,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: const Text('Simpan Profil'),
            ),
          ),
          const Divider(height: 40),
          Text('Agent aktif', style: textTheme.labelMedium),
          const SizedBox(height: 8),
          if (agent != null) ...[
            _InfoRow(label: 'Nama', value: agent.name),
            _InfoRow(label: 'Tujuan', value: agent.purpose),
          ] else
            Text(
              'Belum ada Agent yang dimuat.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          const Divider(height: 40),
          Text('Tentang aplikasi', style: textTheme.labelMedium),
          const SizedBox(height: 8),
          _InfoRow(
            label: 'Versi',
            value: packageInfo != null
                ? '${packageInfo.version}+${packageInfo.buildNumber}'
                : (_packageInfoFailed ? 'Tidak diketahui' : 'Memuat...'),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value),
        ],
      ),
    );
  }
}
