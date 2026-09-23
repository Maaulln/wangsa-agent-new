import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../llm/llm_settings_controller.dart';
import '../../theme/theme_controller.dart';
import '../../voice/voice_input.dart';
import '../../voice/wake_word_lab_page.dart';

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

  const SettingsPage({
    super.key,
    required this.config,
    required this.agentId,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
    this.configProblem,
    this.onApiBaseUrlChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  StreamSubscription<VoiceEvent>? _voiceSubscription;
  late bool _backgroundListening;
  late String _currentApiUrl;

  bool get _wakeWordConfigured => widget.config.wakeWordAccessKey != null;

  @override
  void initState() {
    super.initState();
    _currentApiUrl = widget.config.apiBaseUrl;
    _backgroundListening = widget.voiceInput.status != VoiceStatus.off;
    // Bukan untuk bereaksi terhadap kejadian per kejadian seperti layar
    // chat — hanya supaya sakelar ini ikut berubah kalau wake word
    // dimatikan dari luar (misalnya galat inisialisasi Porcupine).
    _voiceSubscription = widget.voiceInput.events.listen((event) {
      if (event is VoiceFailure) {
        setState(() => _backgroundListening = widget.voiceInput.status != VoiceStatus.off);
      }
    });
  }

  @override
  void dispose() {
    _voiceSubscription?.cancel();
    super.dispose();
  }

  Future<void> _toggleBackgroundListening(bool value) async {
    if (value) {
      await widget.voiceInput.startWakeWordWatch();
    } else {
      await widget.voiceInput.stopWakeWordWatch();
    }
    if (!mounted) return;
    setState(() => _backgroundListening = widget.voiceInput.status != VoiceStatus.off);
  }

  Future<void> _showEditApiDialog() async {
    final controller = TextEditingController(text: _currentApiUrl);
    final formKey = GlobalKey<FormState>();

    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ubah Alamat API Server'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Masukkan alamat backend Wangsa (IP server & port). Tanpa kabel USB, gunakan IP jaringan server Anda.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'URL Server Backend',
                      hintText: 'http://10.9.23.171:9901',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    validator: (val) {
                      final trimmed = (val ?? '').trim();
                      if (trimmed.isEmpty) return 'Alamat URL tidak boleh kosong';
                      if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
                        return 'Harus diawali http:// atau https://';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('Pilihan Cepat:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.wifi, size: 16),
                        label: const Text('10.9.23.171 (WiFi)'),
                        onPressed: () => controller.text = 'http://10.9.23.171:9901',
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.usb, size: 16),
                        label: const Text('localhost (USB)'),
                        onPressed: () => controller.text = 'http://localhost:9901',
                      ),
                    ],
                  ),
                ],
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
      await prefs.setString('wangsa_custom_api_url', clean);
      if (!mounted) return;
      setState(() => _currentApiUrl = clean);
      widget.onApiBaseUrlChanged?.call(clean);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Alamat API diubah ke: '),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
          Text('Model AI', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          const Text(
            'Model dipilih lewat pil model di layar chat — daftarnya '
            'berasal dari provider yang dikonfigurasi di server. Kolom '
            'kunci API (BYOK) di bawah ini peninggalan backend lama dan '
            'sudah tidak dipakai backend saat ini.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          _LlmSection(controller: widget.llmSettings),
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
              onSelectionChanged: (selection) => unawaited(widget.themeController.setMode(selection.first)),
            ),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dengar di latar belakang'),
            subtitle: Text(
              _wakeWordConfigured
                  ? 'Android saja'
                  : 'Belum dikonfigurasi untuk pemasangan ini',
            ),
            trailing: Switch(
              value: _wakeWordConfigured && _backgroundListening,
              onChanged: _wakeWordConfigured ? _toggleBackgroundListening : null,
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Matikan optimasi baterai untuk aplikasi ini agar layanan '
              'mendengar tidak dihentikan sistem. Setelah ponsel dinyalakan '
              'ulang, buka aplikasi sekali agar layanan aktif kembali.',
            ),
          ),
          // TODO(DEMO-20SEP): HAPUS tile debug di bawah ini + file
          // lib/voice/wake_word_lab_page.dart sebelum membangun APK demo
          // 20 September 2026. Alat uji sementara open wake word
          // (sherpa-onnx) di perangkat fisik — bukan bagian produk.
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lab Uji Wake Word (debug)'),
            subtitle: const Text('Uji terisolasi open wake word di HP ini'),
            trailing: const Icon(Icons.bug_report_outlined),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      WakeWordLabPage(voiceInput: widget.voiceInput),
                ),
              );
            },
          ),
        ],
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
              _Field(label: 'Tersimpan (tidak dipakai)', value: 'Kustom: ${override.model}', monospace: true),
              TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Hapus kunci tersimpan'),
              ),
            ],
          );
        }
        return const _Field(label: 'Aktif', value: 'Model server (dipilih di layar chat)');
      },
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;

  const _Field({required this.label, required this.value, this.monospace = false});

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
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
