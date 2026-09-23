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

  const SettingsPage({
    super.key,
    required this.config,
    required this.agentId,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
    this.configProblem,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  StreamSubscription<VoiceEvent>? _voiceSubscription;
  late bool _backgroundListening;

  bool get _wakeWordConfigured => widget.config.wakeWordAccessKey != null;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Field(label: 'Id agent', value: widget.agentId, monospace: true),
          _Field(label: 'Alamat API', value: widget.config.apiBaseUrl),
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
