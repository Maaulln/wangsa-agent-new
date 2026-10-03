import "../../api/api_endpoints.dart";
import "../../api/models.dart";
import "../../api/wangsa_api_client.dart";
import "../../auth/mobile_auth_controller.dart";
import "provider_setup_page.dart";
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../chat/view/chat_icons.dart';
import '../../config/app_config.dart';
import '../../llm/llm_settings_controller.dart';
import '../../profile/user_profile_controller.dart';
import '../../theme/theme_controller.dart';
import '../../theme/wangsa_theme.dart';
import '../../voice/voice_input.dart';

/// Satu layar untuk profil dan pengaturan: profil (nama + preferensi,
/// tersimpan otomatis) di atas, lalu pengaturan, lalu info tentang
/// aplikasi. Dulu profil punya layar sendiri; Wangsa belum punya sistem
/// akun, jadi "profil" hanya dua kolom lokal dan tidak layak dipisah.
///
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

  /// Profil lokal (nama panggilan + preferensi) yang dikirim ke Agent.
  final UserProfileController userProfile;

  /// Agent aktif untuk bagian "Tentang". Null = belum dimuat.
  final PublicAgent? agent;

  const SettingsPage({
    super.key,
    required this.config,
    required this.agentId,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
    required this.userProfile,
    this.agent,
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
  late final TextEditingController _nameController;
  late final TextEditingController _preferencesController;
  final FocusNode _nameFocus = FocusNode();
  Timer? _saveTimer;
  PackageInfo? _packageInfo;
  bool _packageInfoFailed = false;

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
    final profile = widget.userProfile.value;
    _nameController = TextEditingController(text: profile.name);
    _preferencesController = TextEditingController(text: profile.preferences);
    _nameController.addListener(_scheduleProfileSave);
    _preferencesController.addListener(_scheduleProfileSave);
    unawaited(_loadPackageInfo());
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
    // Perubahan terakhir yang belum sempat tersimpan (jeda 600 ms) tetap
    // ditulis saat layar ditutup — pengguna tidak perlu menekan Simpan.
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      unawaited(_saveProfile());
    }
    _nameController.dispose();
    _preferencesController.dispose();
    _nameFocus.dispose();
    _voiceSubscription?.cancel();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  /// Simpan otomatis: tiap ketikan menunda penyimpanan 600 ms, jadi tidak
  /// ada tombol Simpan dan tidak menulis ke disk di setiap huruf.
  void _scheduleProfileSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveProfile);
  }

  Future<void> _saveProfile() {
    return widget.userProfile.save(
      UserProfile(
        name: _nameController.text.trim(),
        preferences: _preferencesController.text.trim(),
      ),
    );
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _packageInfo = info);
    } catch (_) {
      // Sekadar-terbaik — kalau platform tidak bisa memberi info versi,
      // tampil 'Tidak diketahui', bukan macet di 'Memuat...'.
      if (mounted) setState(() => _packageInfoFailed = true);
    }
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
                        prefixIcon: Icon(LucideIcons.server300),
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
                          avatar: const Icon(LucideIcons.usb300, size: 16),
                          label: const Text('localhost (USB)'),
                          onPressed: () =>
                              controller.text = 'http://localhost:9901',
                        ),
                        ActionChip(
                          avatar: const Icon(LucideIcons.monitor300, size: 16),
                          label: const Text('10.0.2.2 (Emulator)'),
                          onPressed: () =>
                              controller.text = 'http://10.0.2.2:9901',
                        ),
                        ActionChip(
                          avatar: const Icon(LucideIcons.radar300, size: 16),
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
                                : const Icon(LucideIcons.wifi300, size: 18),
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
    final auth = widget.auth;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 64,
        leading: const _CircleBackButton(),
        title: const Text(
          'Pengaturan',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          ValueListenableBuilder<UserProfile>(
            valueListenable: widget.userProfile,
            builder: (context, profile, _) => _ProfileHeader(
              // Nama panggilan kosong -> pakai nama akun, supaya header
              // tidak menampilkan "Pengguna" padahal akunnya bernama.
              name: profile.name.trim().isNotEmpty
                  ? profile.name
                  : (auth?.profile ?? ''),
              subtitle: profile.name.trim().isNotEmpty ? auth?.profile : null,
              onEdit: () => _nameFocus.requestFocus(),
            ),
          ),
          const SizedBox(height: 16),
          _SettingsGroup(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            children: [
              _ProfileField(
                label: auth?.profile != null
                    ? 'Nama panggilan (opsional)'
                    : 'Nama panggilan',
                hint: auth?.profile != null
                    ? 'Kosong = ${auth!.profile}'
                    : 'Misal: Doni',
                controller: _nameController,
                focusNode: _nameFocus,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              _ProfileField(
                label: 'Preferensi (opsional)',
                hint: 'Misal: santai, bahasa Indonesia, jawaban singkat',
                controller: _preferencesController,
                minLines: 2,
                maxLines: 4,
              ),
            ],
          ),
          const _FootNote(
            'Tersimpan otomatis di HP ini dan dikirim ke Agent supaya '
            'balasannya sesuai dengan Anda.',
          ),
          const _SectionLabel('Provider & model AI'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: LucideIcons.network300,
                title: 'Setup provider & login AI',
                subtitle:
                    'GitHub Copilot, Anthropic, OpenAI, Gemini, dan lainnya',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProviderSetupPage(apiClient: _client),
                    ),
                  );
                },
              ),
            ],
          ),
          const _SectionLabel('Pemakaian'),
          _BudgetSection(budget: _budget, loading: _loadingBudget),
          const _SectionLabel('Tampilan'),
          // Sebelum ini aplikasi hanya mengikuti mode gelap/terang sistem
          // tanpa cara mengubahnya — identitas visual Wangsa di web
          // memakai palet terang, jadi HP dengan sistem bermode gelap
          // membuat aplikasi ini terlihat tidak senada tanpa diminta.
          // Lihat theme/theme_controller.dart.
          _SettingsGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: ValueListenableBuilder<ThemeMode>(
                  valueListenable: widget.themeController,
                  builder: (context, mode, _) => _ThemeSwitch(
                    mode: mode,
                    onChanged: (next) =>
                        unawaited(widget.themeController.setMode(next)),
                  ),
                ),
              ),
            ],
          ),
          const _SectionLabel('Panggilan suara'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: _backgroundListening
                    ? LucideIcons.ear300
                    : LucideIcons.earOff300,
                iconColor: _backgroundListening ? scheme.primary : null,
                title: _backgroundListening
                    ? 'Kata pemicu aktif'
                    : 'Panggil dengan “${widget.config.wakeWord}”',
                subtitle: !_wakeWordAvailable
                    ? 'Wakeword tidak tersedia pada pemasangan ini.'
                    : _backgroundListening
                    ? 'Wangsa mendengarkan di latar belakang, lalu jeda saat mikrofon dipakai untuk dikte.'
                    : 'Aktifkan untuk memanggil Wangsa tanpa membuka aplikasi.',
                onTap: _wakeWordAvailable && !_wakeWordBusy
                    ? () => _toggleBackgroundListening(!_backgroundListening)
                    : null,
                showChevron: false,
                trailing: Switch.adaptive(
                  value: _wakeWordAvailable && _backgroundListening,
                  onChanged: _wakeWordAvailable && !_wakeWordBusy
                      ? _toggleBackgroundListening
                      : null,
                ),
              ),
            ],
          ),
          if (_wakeWordBusy)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(WangsaRadius.pill),
                child: const LinearProgressIndicator(minHeight: 4),
              ),
            ),
          if (_wakeWordError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(WangsaRadius.md),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.micOff300,
                        size: 20,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: 12),
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
            _FootNote(
              'Wangsa mendengarkan lewat mikrofon saat notifikasi layanan aktif. '
              'Jika Android menghentikannya, izinkan aktivitas latar belakang '
              'untuk Wangsa di pengaturan baterai.',
            ),
          const _SectionLabel('Koneksi'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: LucideIcons.server300,
                title: 'Alamat API backend',
                subtitle: _currentApiUrl,
                monoSubtitle: true,
                trailing: Icon(
                  ChatIcons.edit,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                showChevron: false,
                onTap: _showEditApiDialog,
              ),
              _SettingsRow(
                icon: LucideIcons.hash300,
                title: 'Id agent',
                subtitle: widget.agentId,
                monoSubtitle: true,
              ),
              _SettingsRow(
                icon: LucideIcons.audioLines300,
                title: 'Kata pemicu',
                subtitle: widget.config.wakeWord,
              ),
              _SettingsRow(
                icon: LucideIcons.cog300,
                title: 'Sumber konfigurasi',
                subtitle: widget.configProblem == null
                    ? 'berkas konfigurasi di server'
                    : 'nilai cadangan bawaan aplikasi',
              ),
            ],
          ),
          if (widget.configProblem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                widget.configProblem!,
                style: TextStyle(color: scheme.error, fontSize: 13),
              ),
            ),
          const _SectionLabel('Tentang'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: LucideIcons.bot300,
                title: 'Agent aktif',
                subtitle: widget.agent?.name ?? 'Belum ada Agent yang dimuat.',
              ),
              if (widget.agent != null)
                _SettingsRow(
                  icon: LucideIcons.target300,
                  title: 'Tujuan',
                  subtitle: widget.agent!.purpose,
                ),
              _SettingsRow(
                icon: LucideIcons.info300,
                title: 'Versi aplikasi',
                subtitle: _packageInfo != null
                    ? '${_packageInfo!.version}+${_packageInfo!.buildNumber}'
                    : (_packageInfoFailed ? 'Tidak diketahui' : 'Memuat...'),
              ),
            ],
          ),
          if (auth != null) ...[
            const SizedBox(height: 24),
            _SettingsGroup(
              children: [
                _SettingsRow(
                  icon: ChatIcons.signOut,
                  title: 'Keluar',
                  destructive: true,
                  onTap: () => _logout(context),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Tombol kembali bulat di AppBar, senada dengan tombol bulat di layar chat.
class _CircleBackButton extends StatelessWidget {
  const _CircleBackButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Tooltip(
        message: 'Kembali',
        child: InkResponse(
          radius: 24,
          onTap: () => Navigator.of(context).maybePop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outline),
            ),
            child: Icon(ChatIcons.back, size: 20, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _FootNote extends StatelessWidget {
  final String text;

  const _FootNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }
}

/// Kartu berlengkung yang membungkus beberapa baris dengan garis pemisah.
/// Memakai [Material] (bukan Container berwarna) supaya efek sentuh baris
/// di dalamnya tidak tertutup latar kartu.
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;

  /// Bila diisi, isi grup dibungkus padding dan tanpa garis pemisah
  /// (dipakai untuk kartu formulir, bukan daftar baris).
  final EdgeInsetsGeometry? padding;

  const _SettingsGroup({required this.children, this.padding});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WangsaRadius.lg),
        side: BorderSide(color: scheme.outline),
      ),
      child: padding != null
          ? Padding(
              padding: padding!,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, indent: 54, color: scheme.outline),
                  children[i],
                ],
              ],
            ),
    );
  }
}

/// Avatar inisial + nama di puncak layar. Tombol pensil memindahkan fokus
/// ke kolom nama (belum ada foto profil, jadi hanya nama yang diubah).
class _ProfileHeader extends StatelessWidget {
  final String name;
  final String? subtitle;
  final VoidCallback onEdit;

  const _ProfileHeader({
    required this.name,
    required this.onEdit,
    this.subtitle,
  });

  String get _initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initials = _initials;
    return Column(
      children: [
        const SizedBox(height: 8),
        SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: initials.isEmpty
                        ? Icon(
                            ChatIcons.profile,
                            size: 36,
                            color: scheme.onPrimaryContainer,
                          )
                        : Text(
                            initials,
                            style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontSize: 32,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                  ),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Tooltip(
                  message: 'Ubah nama',
                  child: InkResponse(
                    onTap: onEdit,
                    radius: 22,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outline),
                      ),
                      child: Icon(
                        ChatIcons.edit,
                        size: 15,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          name.trim().isEmpty ? 'Pengguna' : name.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          ),
        ],
      ],
    );
  }
}

class _ProfileField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final int minLines;
  final int maxLines;

  const _ProfileField({
    required this.label,
    required this.hint,
    required this.controller,
    this.focusNode,
    this.textInputAction,
    this.minLines = 1,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Satu baris = pil penuh; multi-baris memakai radius xl supaya sudut
    // tidak menggembung saat kolom membesar.
    final radius = maxLines == 1 ? WangsaRadius.pill : WangsaRadius.xl;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: color),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            label,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          ),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: textInputAction,
          minLines: minLines,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 14,
            ),
            border: border(scheme.outline),
            enabledBorder: border(scheme.outline),
            focusedBorder: border(scheme.onSurface.withValues(alpha: 0.5)),
          ),
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final bool monoSubtitle;
  final Widget? trailing;
  final bool showChevron;
  final bool destructive;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    this.iconColor,
    this.subtitle,
    this.monoSubtitle = false,
    this.trailing,
    this.showChevron = true,
    this.destructive = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : scheme.onSurface;
    final end =
        trailing ??
        (onTap != null && showChevron && !destructive
            ? Icon(
                ChatIcons.chevronRight,
                size: 18,
                color: scheme.onSurfaceVariant,
              )
            : null);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: iconColor ?? color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                          height: 1.3,
                          fontFamily: monoSubtitle ? 'monospace' : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (end != null) ...[const SizedBox(width: 12), end],
            ],
          ),
        ),
      ),
    );
  }
}

/// Pilihan tema berbentuk pil, senada dengan sakelar Chat/Work di layar
/// chat. Radius segmen = radius pil dikurangi padding (konsentris).
class _ThemeSwitch extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeSwitch({required this.mode, required this.onChanged});

  static const _options = [
    (ThemeMode.system, 'Sistem', LucideIcons.sunMoon300),
    (ThemeMode.light, 'Terang', LucideIcons.sun300),
    (ThemeMode.dark, 'Gelap', LucideIcons.moon300),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(WangsaRadius.pill),
      ),
      child: Row(
        children: [
          for (final (value, label, icon) in _options)
            Expanded(
              child: Semantics(
                button: true,
                selected: mode == value,
                label: label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(WangsaRadius.pill),
                  onTap: () => onChanged(value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: mode == value
                          ? scheme.onSurface.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(WangsaRadius.pill),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 16,
                          color: mode == value
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: mode == value
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: mode == value
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ringkasan budget spend profile: progres harian + bulanan bila ada cap,
/// status peringatan, atau pesan tercapai. Read-only — ubah cap lewat
/// dashboard / config.yaml (budgets.daily_usd/monthly_usd).
class _BudgetSection extends StatelessWidget {
  final BudgetInfo? budget;
  final bool loading;

  const _BudgetSection({required this.budget, required this.loading});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = budget;
    if (loading && b == null) {
      return const _SettingsGroup(
        children: [
          _SettingsRow(
            icon: LucideIcons.gauge300,
            title: 'Memuat pemakaian…',
            trailing: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ],
      );
    }
    if (b == null || !b.hasCap) {
      return const _SettingsGroup(
        children: [
          _SettingsRow(
            icon: LucideIcons.gauge300,
            title: 'Pemakaian',
            subtitle: 'Tanpa batas (unlimited)',
          ),
        ],
      );
    }
    final accent = b.isBreached ? scheme.error : scheme.primary;
    return _SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    b.isBreached ? LucideIcons.ban300 : LucideIcons.gauge300,
                    size: 22,
                    color: accent,
                  ),
                  const SizedBox(width: 16),
                  Text(
                    b.isBreached ? 'Budget tercapai' : 'Pemakaian',
                    style: TextStyle(
                      color: b.isBreached ? scheme.error : scheme.onSurface,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              if (b.dailyUsd != null)
                _UsageBar(
                  label:
                      'Harian \$${b.spentDay.toStringAsFixed(2)} / \$${b.dailyUsd!.toStringAsFixed(2)}',
                  value: b.dayPct,
                  color: accent,
                ),
              if (b.monthlyUsd != null)
                _UsageBar(
                  label:
                      'Bulanan \$${b.spentMonth.toStringAsFixed(2)} / \$${b.monthlyUsd!.toStringAsFixed(2)}',
                  value: b.monthPct,
                  color: accent,
                ),
              if (b.alert && !b.isBreached)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Mendekati batas.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UsageBar extends StatelessWidget {
  final String label;
  final double value;
  final Color color;

  const _UsageBar({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(WangsaRadius.pill),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
