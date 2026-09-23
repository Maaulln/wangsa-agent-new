import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../api/models.dart';

/// Kerangka halaman profil — BELUM ada sistem akun/login di Wangsa sama
/// sekali. Mobile bicara ke Agent publik tanpa identitas apa pun (lihat
/// catatan `PublicAgent` di `api/models.dart`), jadi tidak ada nama,
/// foto, atau data pengguna sungguhan untuk ditampilkan di sini. Halaman
/// ini jujur soal itu alih-alih berpura-pura: yang ditunjukkan hanya info
/// yang benar-benar nyata sekarang (Agent yang sedang aktif, info
/// aplikasi), siap diisi kalau backend akun pernah dibuat nanti.
class ProfilePage extends StatefulWidget {
  final PublicAgent? agent;

  const ProfilePage({super.key, required this.agent});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  PackageInfo? _packageInfo;
  bool _packageInfoFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPackageInfo());
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
            'Tidak ada login — siapa pun bisa memakai Agent yang sudah '
            'dipublikasikan tanpa perlu masuk akun.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
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
