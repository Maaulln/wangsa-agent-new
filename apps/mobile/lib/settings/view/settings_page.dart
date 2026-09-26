import "../../api/api_endpoints.dart";
import "../../api/models.dart";
import "../../api/wangsa_api_client.dart";
import "../../auth/mobile_auth_controller.dart";
import "provider_setup_page.dart";
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../llm/llm_settings_controller.dart';
import '../../theme/theme_controller.dart';
import '../../voice/voice_input.dart';

/// Layar pengaturan sengaja kecil.
///
/// Semua yang bisa diatur dari server tidak perlu muncul sebagai kolom
/// isian di sini. Yang ditampilkan hanya apa yang sedang berlaku, dari
/// mana asalnya, dan peringatan yang menentukan apakah wake word akan
/// bertahan di perangkat ini.
class SettingsPage extends StatefulWidget {
  final AppConfig config;
  final String? configProblem;
  final String agentId;

  /// Instance yang sama dipegang layar chat (lihat chat_page.dart) —
  /// sakelar di layar ini mengendalikan mesin yang sedang berjalan,
  /// bukan instance baru.
  final VoiceInput voiceInput;

  /// Lihat theme/theme_controller.dart — satu instance yang sama dipegang
  /// sepanjang umur aplikasi, sama seperti [voiceInput].
  final ThemeController themeController;

  /// Pengaturan model AI (BYOK) — instance yang sama dipegang main.dart
  /// dan ChatBloc, supaya pesan berikutnya memakai kunci yang baru
  /// disimpan tanpa mulai ulang.
  final LlmSettingsController llmSettings;
  final ValueChanged<String>? onApiBaseUrlChanged;

  /// Klien ber-token (dari ChatBloc) agar Setup Provider + budget + logout
  /// berjalan dalam profile pengguna. Null = fallback client tanpa token
  /// (kompatibilitas test lama / server localhost-terbuka).
  final WangsaApiClient? apiClient;

  /// Sesi auth untuk nama profile + logout. Null = sembunyikan seksi akun.
  final MobileAuthController? auth;

  const SettingsPage({
    super.key,
    required this.config,
    required this.agentId,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
    this.configProblem,
    this.onApiBaseUrlChanged,
    this.apiClient,
    this.auth,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  StreamSubscription<VoiceEvent>? _voiceSubscription;
  late bool _backgroundListening;
  late String _currentApiUrl;
  late final WangsaApiClient _client;
  late final bool _ownsClient;
  BudgetInfo? _budget;
  bool _loadingBudget = false;
  bool _wakeWordBusy = false;
  String? _wakeWordError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Satu kali: muat budget saat halaman dibuka.
    if (_budget == null && !_loadingBudget && widget.apiClient != null) {
      _loadingBudget = true;
      widget.apiClient!.getBudget().then((res) {
        if (!mounted) return;
        setState(() {
          _loadingBudget = false;
          if (res.isSuccess) _budget = res.dataOrNull;
        });
      });
    }
  }

  bool get _wakeWordAvailable => widget.voiceInput.wakeWordAvailable;

  bool _isWakeWordFailure(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('wake word') ||
        normalized.contains('kata pemicu');
  }

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.apiClient == null;
    _client =
        widget.apiClient ?? WangsaApiClient(baseUrl: widget.config.apiBaseUrl);
    _currentApiUrl = widget.config.apiBaseUrl;
    _backgroundListening = widget.voiceInput.wakeWordEnabled;
    // Sinkronkan sakelar dengan listener yang mulai otomatis saat bootstrap.
    _voiceSubscription = widget.voiceInput.events.listen((event) {
      if (!mounted) return;
      if (event is WakeWordStatusChanged) {
        setState(() {
          _backgroundListening = event.enabled;
          _wakeWordError = null;
        });
      } else if (event is VoiceFailure && _isWakeWordFailure(event.message)) {
        setState(() {
          _backgroundListening = false;
          _wakeWordError = event.message;
        });
      }
    });
  }

  @override
  void dispose() {
    _voiceSubscription?.cancel();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _toggleBackgroundListening(bool value) async {
    if (_wakeWordBusy || !_wakeWordAvailable) return;
    setState(() {
      _wakeWordBusy = true;
      _wakeWordError = null;
    });
    try {
      if (value) {
        await widget.voiceInput.startWakeWordWatch();
      } else {
        await widget.voiceInput.stopWakeWordWatch();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _backgroundListening = false;
          _wakeWordError =
              'Wangsa tidak bisa mulai mendengarkan. Periksa izin mikrofon, lalu coba lagi.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _wakeWordBusy = false;
          _backgroundListening = widget.voiceInput.wakeWordEnabled;
        });
      }
    }
  }

  Future<void> _logout(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar?'),
        content: const Text(
          'Token perangkat ini dicabut dari server dan sesi lokal dihapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    // Best-effort revoke: token env-managed (409) tetap bisa keluar lokal.
    try {
      await _client.revokeToken();
    } catch (_) {
      // Abaikan — sesi lokal tetap dibersihkan di bawah.
    }
    _client.updateToken(null);
    await widget.auth?.clear();
    if (!context.mounted) return;
    // Kembali ke gerbang auth (AuthGate rebuild via listener).
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Ping ringan ke URL yang diketik: `GET /api/v1/agents/:id` itu publik
  /// (tanpa token), jadi cocok untuk memastikan "servernya hidup?" sebelum
  /// menyimpan. Mengembalikan pesan Indonesia siap tampil.
  Future<String> _testConnection(String url) async {
    final probe = WangsaApiClient(
      baseUrl: url,
      requestTimeout: const Duration(seconds: 5),
    );
    try {
      final res = await probe.getAgent(widget.agentId);
      if (res.isSuccess) {
        final name = res.dataOrNull?.name.trim();
        return 'Terhubung${name != null && name.isNotEmpty ? ' ke "$name"' : ''}.';
      }
      final code = res.errorOrNull?.code;
      if (code == 'RUNTIME_ERROR') {
        return 'Tak terjangkau. ${diagnoseConnectionHint(url)}';
      }
      return res.errorOrNull?.message ?? 'Server menjawab tapi ada masalah.';
    } catch (_) {
      return 'Tak terjangkau. ${diagnoseConnectionHint(url)}';
    } finally {
      probe.close();
    }
  }

  Future<void> _showEditApiDialog() async {
    final controller = TextEditingController(text: _currentApiUrl);
    final formKey = GlobalKey<FormState>();
    String? testStatus;
    bool testing = false;

    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ubah Alamat API Server'),
          content: StatefulBuilder(
            builder: (stateContext, setDialogState) => Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pilih jalur sesuai perangkat: localhost untuk HP via kabel USB '
                      '(+ adb reverse), 10.0.2.2 khusus emulator, atau IP LAN laptop '
                      'bila HP dan laptop satu Wi-Fi.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: controller,
                      decoration: const InputDecoration(
                        labelText: 'URL Server Backend',
                        hintText: 'http://localhost:9901',
                        prefixIcon: Icon(Icons.dns_outlined),
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                      validator: (val) {
                        final trimmed = (val ?? '').trim();
                        if (trimmed.isEmpty) {
                          return 'Alamat URL tidak boleh kosong';
                        }
                        if (!trimmed.startsWith('http://') &&
                            !trimmed.startsWith('https://')) {
                          return 'Harus diawali http:// atau https://';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Pilihan Cepat:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        ActionChip(
                          avatar: const Icon(Icons.usb, size: 16),
                          label: const Text('localhost (USB)'),
                          onPressed: () =>
                              controller.text = 'http://localhost:9901',
                        ),
                        ActionChip(
                          avatar: const Icon(
                            Icons.desktop_windows_outlined,
                            size: 16,
                          ),
                          label: const Text('10.0.2.2 (Emulator)'),
                          onPressed: () =>
                              controller.text = 'http://10.0.2.2:9901',
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.radar_rounded, size: 16),
                          label: const Text('Deteksi otomatis'),
                          onPressed: testing
                              ? null
                              : () async {
                                  setDialogState(() {
                                    testing = true;
                                    testStatus = 'Menelusuri jaringan lokal…';
                                  });
                                  List<String> found;
                                  try {
                                    found = await discoverLanBackendUrls(
                                      agentId: widget.agentId,
                                    );
                                  } catch (_) {
                                    found = const [];
                                  }
                                  if (!stateContext.mounted) return;
                                  setDialogState(() {
                                    testing = false;
                                    if (found.isEmpty) {
                                      testStatus =
                                          'Tidak menemukan backend di jaringan ini. '
                                          'Pastikan HP dan laptop satu Wi-Fi, lalu coba lagi.';
                                    } else {
                                      controller.text = found.first;
                                      testStatus =
                                          'Ditemukan ${found.length} backend — URL sudah terisi.';
                                    }
                                  });
                                },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: testing
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.wifi_find_rounded, size: 18),
                            label: Text(
                              testing ? 'Menghubungi…' : 'Tes koneksi',
                            ),
                            onPressed: testing
                                ? null
                                : () async {
                                    final url = controller.text.trim();
                                    if (url.isEmpty) {
                                      setDialogState(
                                        () => testStatus =
                                            'Isi dulu URL-nya, baru tes.',
                                      );
                                      return;
                                    }
                                    setDialogState(() {
                                      testing = true;
                                      testStatus = null;
                                    });
                                    final status = await _testConnection(url);
                                    if (stateContext.mounted) {
                                      setDialogState(() {
                                        testing = false;
                                        testStatus = status;
                                      });
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    if (testStatus != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        testStatus!,
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              testStatus!.startsWith('Terhubung') ||
                                  testStatus!.startsWith('Ditemukan')
                              ? Colors.green.shade700
                              : testStatus!.startsWith('Menelusuri')
                              ? Theme.of(
                                  stateContext,
                                ).colorScheme.onSurfaceVariant
                              : Theme.of(stateContext).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(controller.text.trim());
                }
              },
              child: const Text('Simpan & Hubungkan'),
            ),
          ],
        );
      },
    );

    if (newUrl != null && newUrl.isNotEmpty && newUrl != _currentApiUrl) {
      final clean = newUrl.replaceAll(RegExp(r'/+$'), '');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wangsa_chat_api_url', clean);
      if (!mounted) return;
      setState(() => _currentApiUrl = clean);
      widget.onApiBaseUrlChanged?.call(clean);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Alamat API diubah ke: $clean'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Field(label: 'Id agent', value: widget.agentId, monospace: true),
          _ApiUrlTile(url: _currentApiUrl, onTap: _showEditApiDialog),
          _Field(label: 'Kata pemicu', value: widget.config.wakeWord),
          _Field(
            label: 'Sumber konfigurasi',
            value: widget.configProblem == null
                ? 'berkas konfigurasi di server'
                : 'nilai cadangan bawaan aplikasi',
          ),
          if (widget.configProblem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.configProblem!,
                style: TextStyle(color: scheme.error),
              ),
            ),
          const Divider(height: 32),
          Text(
            'Provider & Model AI',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Koneksikan provider AI Anda (GitHub Copilot, Anthropic, OpenAI, Gemini, dll.) '
            'seperti alur hermes setup agar Agent bisa terhubung.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: ListTile(
              leading: Icon(Icons.hub_rounded, color: scheme.primary),
              title: const Text(
                'Setup Provider & Login AI',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Konfigurasi API Key & autentikasi provider',
                style: TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProviderSetupPage(apiClient: _client),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _BudgetCard(budget: _budget, loading: _loadingBudget),
          if (widget.auth != null) ...[
            const Divider(height: 32),
            Text('Akun', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: ListTile(
                leading: Icon(
                  Icons.person_outline_rounded,
                  color: scheme.primary,
                ),
                title: Text(
                  widget.auth!.profile ?? 'Pengguna',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Satu akun = satu profile terisolasi',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Keluar'),
              onPressed: () => _logout(context),
            ),
          ],
          const Divider(height: 32),
          Text('Tampilan', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          // Sebelum ini aplikasi hanya mengikuti mode gelap/terang sistem
          // tanpa cara mengubahnya — identitas visual Wangsa di web
          // memakai palet terang, jadi HP dengan sistem bermode gelap
          // membuat aplikasi ini terlihat tidak senada tanpa diminta.
          // Lihat theme/theme_controller.dart.
          ValueListenableBuilder<ThemeMode>(
            valueListenable: widget.themeController,
            builder: (context, mode, _) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('Sistem'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Terang'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Gelap'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) =>
                  unawaited(widget.themeController.setMode(selection.first)),
            ),
          ),
          const Divider(height: 32),
          Text(
            'Panggilan suara',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              _backgroundListening
                  ? Icons.hearing_rounded
                  : Icons.hearing_disabled_rounded,
              color: _backgroundListening
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            title: Text(
              _backgroundListening
                  ? 'Kata pemicu aktif'
                  : 'Panggil dengan “${widget.config.wakeWord}”',
            ),
            subtitle: Text(
              !_wakeWordAvailable
                  ? 'Wakeword tidak tersedia pada pemasangan ini.'
                  : _backgroundListening
                  ? 'Wangsa mendengarkan di latar belakang, lalu jeda saat mikrofon dipakai untuk dikte.'
                  : 'Aktifkan untuk memanggil Wangsa tanpa membuka aplikasi.',
            ),
            value: _wakeWordAvailable && _backgroundListening,
            onChanged: _wakeWordAvailable && !_wakeWordBusy
                ? _toggleBackgroundListening
                : null,
          ),
          if (_wakeWordBusy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(),
            ),
          if (_wakeWordError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.mic_off_outlined,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _wakeWordError!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                      TextButton(
                        onPressed: _wakeWordBusy || !_wakeWordAvailable
                            ? null
                            : () => _toggleBackgroundListening(true),
                        child: const Text('Coba lagi'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_wakeWordAvailable)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
              child: Text(
                'Wangsa mendengarkan lewat mikrofon saat notifikasi layanan aktif. '
                'Jika Android menghentikannya, izinkan aktivitas latar belakang '
                'untuk Wangsa di pengaturan baterai.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// Kartu ringkasan budget spend profile: progres harian + bulanan bila
/// ada cap, status peringatan, atau pesan tercapai. Read-only — ubah cap
/// lewat dashboard / config.yaml (budgets.daily_usd/monthly_usd).
class _BudgetCard extends StatelessWidget {
  final BudgetInfo? budget;
  final bool loading;

  const _BudgetCard({required this.budget, required this.loading});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = budget;
    if (loading && b == null) {
      return const Card(
        child: ListTile(
          leading: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Memuat pemakaian…', style: TextStyle(fontSize: 13)),
        ),
      );
    }
    if (b == null || !b.hasCap) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.data_usage_outlined),
          title: Text(
            'Pemakaian',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          subtitle: Text(
            'Tanpa batas (unlimited)',
            style: TextStyle(fontSize: 12),
          ),
        ),
      );
    }
    return Card(
      elevation: 0,
      color:
          (b.isBreached
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest)
              .withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  b.isBreached
                      ? Icons.block_rounded
                      : Icons.data_usage_outlined,
                  color: b.isBreached ? scheme.error : scheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  b.isBreached ? 'Budget tercapai' : 'Pemakaian',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            if (b.dailyUsd != null) ...[
              const SizedBox(height: 10),
              Text(
                'Harian \$${b.spentDay.toStringAsFixed(2)} / \$${b.dailyUsd!.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: b.dayPct),
            ],
            if (b.monthlyUsd != null) ...[
              const SizedBox(height: 10),
              Text(
                'Bulanan \$${b.spentMonth.toStringAsFixed(2)} / \$${b.monthlyUsd!.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: b.monthPct),
            ],
            if (b.alert && !b.isBreached)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Mendekati batas.', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Status BYOK peninggalan: backend saat ini mengabaikan kunci ini
/// (lihat `WangsaApiClient.sendMessage`), jadi layar ini tidak lagi
/// menawarkan formulir isi kunci — hanya tombol bersih-bersih untuk
/// menghapus kunci yang masih tersimpan di brankas HP ini.
class _LlmSection extends StatefulWidget {
  final LlmSettingsController controller;

  const _LlmSection({required this.controller});

  @override
  State<_LlmSection> createState() => _LlmSectionState();
}

class _LlmSectionState extends State<_LlmSection> {
  Future<void> _reset() async {
    await widget.controller.useDefault();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.controller,
      builder: (context, override, _) {
        if (override != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                label: 'Tersimpan (tidak dipakai)',
                value: 'Kustom: ${override.model}',
                monospace: true,
              ),
              TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Hapus kunci tersimpan'),
              ),
            ],
          );
        }
        return const _Field(
          label: 'Aktif',
          value: 'Model server (dipilih di layar chat)',
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;

  const _Field({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: monospace ? const TextStyle(fontFamily: 'monospace') : null,
          ),
        ],
      ),
    );
  }
}

class _ApiUrlTile extends StatelessWidget {
  final String url;
  final VoidCallback onTap;

  const _ApiUrlTile({required this.url, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, color: scheme.primary, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Alamat API Backend',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Sentuh untuk ubah',
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        url,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Ubah Alamat API',
                  onPressed: onTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
