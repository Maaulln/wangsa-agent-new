import "../../api/wangsa_api_client.dart";
import "../../auth/mobile_auth_controller.dart";
import "../../settings/view/provider_setup_page.dart";
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/models.dart';
import '../../config/app_config.dart';
import '../../llm/llm_settings_controller.dart';
import '../../profile/user_profile_controller.dart';
import '../../api/api_endpoints.dart';
import '../../settings/view/settings_page.dart';
import '../../theme/glass/wangsa_glass.dart';
import '../../theme/theme_controller.dart';
import '../../theme/wangsa_theme.dart';
import '../../voice/voice_input.dart';
import '../bloc/chat_bloc.dart';
import 'agent_builder_page.dart';
import '../../product/product_app.dart';
import 'chat_icons.dart';
import 'message_bubble.dart';
import 'widgets/chat_notice.dart';
import 'widgets/thinking_indicator.dart';
import 'widgets/voice_orb.dart';

/// Palet gelap lokal khusus tampilan ChatPage (header + composer), meniru
/// referensi desain Figma "ChatGPT UI Kit" (node 676:2547). Sengaja TIDAK
/// menyentuh `WangsaTheme` global — halaman lain tetap ikut mode
/// terang/gelap sistem seperti biasa; hanya kartu chat ini yang selalu
/// gelap solid, sesuai keputusan pengguna saat sesi ini.
abstract final class _ChatDark {
  static const pill = Color(0xFF1C1C1E);
  // #AEAEB2 (bukan #8E8E93): kontras >= 5:1 di atas kaca.
  static const hint = Color(0xFFAEAEB2);
  // Putih di atas #0A6CFF = 4,56:1 (di atas #0A84FF hanya 3,65:1).
  static const accent = Color(0xFF0A6CFF);
  // Sedikit terangkat dari hitam pekat supaya lengkung sudut drawer
  // terlihat di atas latar kaca gelap.
  static const drawer = Color(0xFF000000);
  static const rowSelected = Color(0x14FFFFFF);
  static const groupBorder = Color(0x0FFFFFFF);
}

/// Satu gambar yang menunggu dikirim — sudah dibaca ke memori supaya
/// pengiriman tidak menyentuh kanal platform lagi.
class PendingImage {
  final Uint8List bytes;
  final String mimeType;
  final String filename;

  const PendingImage({
    required this.bytes,
    this.mimeType = 'image/jpeg',
    this.filename = 'gambar.jpg',
  });
}

/// Layar utama, dan satu-satunya layar yang dilihat pengguna akhir.
///
/// Chat adalah rumah tetapnya — selalu terlihat, tidak pernah diganti
/// oleh layar lain. Suara adalah lapisan yang muncul MENIMPA layar ini
/// saat mikrofon ditekan atau kata pemicu terdengar, lalu menghilang
/// sendiri begitu ucapan selesai dikirim. Awalnya suara sempat dibuat
/// sebagai tab sejajar dengan chat (rancangan Yardan, lihat riwayat git),
/// tapi itu janggal: wake word bisa menyela dari tab mana pun, jadi ia
/// bukan tab, melainkan sesuatu yang menyela. Lihat README.md, bagian
/// "Yang masih perlu disesuaikan".
///
/// Tata letak composer diambil dari pola aplikasi Claude (kartu dua baris:
/// teks lalu ikon), dan lapisan suara (termasuk `VoiceOrb`) sudah lewat
/// token `WangsaTheme`, sehingga keduanya otomatis mengikuti mode
/// gelap/terang sistem. Yang TIDAK dipindahkan adalah mesin suaranya:
/// `NativeVoiceInput` tetap dipakai, hanya dibungkus antarmuka
/// `VoiceInput` supaya layar ini bisa diuji tanpa menyentuh perangkat
/// keras mikrofon (lihat `test/chat/chat_page_test.dart`).
class ChatPage extends StatefulWidget {
  final VoiceInput voiceInput;
  final AppConfig config;
  final String? configProblem;
  final ThemeController themeController;
  final LlmSettingsController llmSettings;
  final UserProfileController userProfile;

  /// Sesi auth (token + profile). Opsional agar test widget lama yang
  /// membangun ChatPage langsung tetap kompilasi — produksi selalu isi
  /// dari AuthGate. Dipakai untuk logout + budget di SettingsPage.
  final MobileAuthController? auth;

  /// Diteruskan ke AuthGate setiap URL berubah dari Pengaturan, supaya
  /// kunci sesi + SharedPreferences selaras dengan klien ChatBloc.
  /// Tanpa ini, perbaikan URL dari Pengaturan hilang saat sesi dibangun
  /// ulang (dan AuthGate kembali memakai URL basi).
  final ValueChanged<String>? onApiBaseUrlChanged;

  /// Hook pengujian: menggantikan `ImagePicker().pickImage()` bawaan
  /// supaya tes widget bisa menyuntikkan gambar tanpa menyentuh kamera/
  /// galeri sungguhan perangkat.
  final Future<PendingImage?> Function()? pickImage;

  const ChatPage({
    super.key,
    required this.voiceInput,
    required this.config,
    this.configProblem,
    required this.themeController,
    required this.llmSettings,
    required this.userProfile,
    this.auth,
    this.pickImage,
    this.onApiBaseUrlChanged,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  late AppConfig _activeConfig = widget.config;
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _followLatest = true;
  bool _showLatestButton = false;
  int _lastObservedTurnCount = 0;

  StreamSubscription<VoiceEvent>? _voiceSubscription;
  VoiceStatus _voiceStatus = VoiceStatus.off;
  double _soundLevel = 0.0;
  String? _voiceError;

  /// Lapisan suara sedang menimpa layar chat. Dibuka waktu tombol mikrofon
  /// ditekan atau kata pemicu terdengar, ditutup waktu ucapan selesai
  /// dikirim atau tombol Batal ditekan.
  bool _voiceOverlayOpen = false;

  static const List<Map<String, String>> _slashCommands = [
    {'command': '/status', 'desc': 'Status runtime & gateway agent'},
    {'command': '/model', 'desc': 'Ganti atau cek model AI aktif'},
    {'command': '/new', 'desc': 'Mulai sesi percakapan baru'},
    {'command': '/reset', 'desc': 'Reset konteks percakapan saat ini'},
    {'command': '/skills', 'desc': 'Daftar skill & kemampuan agent'},
    {'command': '/mcp', 'desc': 'Status koneksi tool MCP'},
  ];

  @override
  void initState() {
    super.initState();
    _voiceStatus = widget.voiceInput.status;
    _scrollController.addListener(_handleScrollPosition);
    WidgetsBinding.instance.addObserver(this);
    _voiceSubscription = widget.voiceInput.events.listen(_onVoiceEvent);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (_followLatest &&
        views.isNotEmpty &&
        views.first.viewInsets.bottom > 0) {
      _scrollToLatest();
    }
  }

  void _handleScrollPosition() {
    if (!_scrollController.hasClients) return;
    final nearLatest = _scrollController.position.extentAfter <= 140;
    _followLatest = nearLatest;
    final shouldShow = !nearLatest;
    if (_showLatestButton != shouldShow && mounted) {
      setState(() => _showLatestButton = shouldShow);
    }
  }

  @override
  void dispose() {
    _voiceSubscription?.cancel();
    _scrollController.removeListener(_handleScrollPosition);
    _draftController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.voiceInput.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isListening => _voiceStatus == VoiceStatus.listening;

  void _onVoiceEvent(VoiceEvent event) {
    if (!mounted) return;
    switch (event) {
      case WakeWordDetected():
        setState(() {
          _voiceOverlayOpen = true;
          _voiceError = null;
          _voiceStatus = widget.voiceInput.status;
        });
      case WakeWordStatusChanged():
        break;
      case PartialTranscript(text: final text):
        setState(() {
          _voiceStatus = widget.voiceInput.status;
          _draftController.text = text;
        });
      case FinalTranscript(text: final text):
        // Lapisan suara langsung ditutup di sini, bukan menunggu balasan
        // Agent — begitu ucapan selesai, tugas lapisan ini selesai, dan
        // giliran layar chat di baliknya yang menunjukkan kelanjutannya.
        setState(() {
          _voiceStatus = widget.voiceInput.status;
          _voiceOverlayOpen = false;
          _soundLevel = 0;
        });
        if (text.trim().isNotEmpty) {
          context.read<ChatBloc>().add(MessageSubmitted(text));
        }
        _draftController.clear();
      case VoiceFailure(message: final message):
        setState(() {
          _voiceStatus = widget.voiceInput.status;
          _voiceError = message;
          _voiceOverlayOpen = true;
          _soundLevel = 0;
        });
      case SoundLevelChanged(level: final level):
        setState(() => _soundLevel = level);
    }
  }

  Future<void> _toggleListening() async {
    unawaited(HapticFeedback.lightImpact());
    setState(() => _voiceError = null);
    if (_isListening) {
      await widget.voiceInput.stop();
      if (mounted) setState(() => _voiceOverlayOpen = false);
    } else {
      setState(() => _voiceOverlayOpen = true);
      await widget.voiceInput.startListening();
    }
    if (mounted) {
      setState(() {
        _voiceStatus = widget.voiceInput.status;
        _soundLevel = 0;
      });
    }
  }

  Future<void> _cancelVoiceOverlay() async {
    await widget.voiceInput.stop();
    if (!mounted) return;
    setState(() {
      _voiceOverlayOpen = false;
      _voiceError = null;
      _voiceStatus = widget.voiceInput.status;
      _soundLevel = 0;
    });
  }

  /// Gambar yang menunggu dikirim bersama pesan berikutnya. Maksimal
  /// [_maxPendingImages] — server juga membatasi jumlah per pesan.
  static const _maxPendingImages = 5;
  final List<PendingImage> _pendingImages = [];

  bool get _hasPendingImages => _pendingImages.isNotEmpty;

  Future<void> _showAttachmentPicker() async {
    if (widget.pickImage != null) {
      await _pickImage(source: ImageSource.gallery);
      return;
    }
    unawaited(HapticFeedback.lightImpact());
    final bloc = context.read<ChatBloc>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(WangsaRadius.xl),
        ),
      ),
      builder: (sheetContext) => BlocProvider.value(
        value: bloc,
        child: BlocBuilder<ChatBloc, ChatState>(
          builder: (context, state) {
            final locked = state.turns.isNotEmpty || state.sessionId != null;
            final selected = state.selectedToolsets.toSet();
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        'Kapabilitas chat',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(ChatIcons.web),
                      title: const Text('Pencarian web'),
                      subtitle: const Text(
                        'Izinkan Wangsa mencari informasi terbaru',
                      ),
                      value: selected.contains('web'),
                      onChanged: locked || state.isSending
                          ? null
                          : (enabled) {
                              final next = {...selected};
                              enabled ? next.add('web') : next.remove('web');
                              bloc.add(ToolsetsSelected(next.toList()));
                            },
                    ),
                    SwitchListTile(
                      secondary: const Icon(ChatIcons.image),
                      title: const Text('Analisis gambar'),
                      subtitle: const Text(
                        'Izinkan Wangsa memahami gambar yang dikirim',
                      ),
                      value: selected.contains('vision'),
                      onChanged: locked || state.isSending
                          ? null
                          : (enabled) {
                              final next = {...selected};
                              enabled
                                  ? next.add('vision')
                                  : next.remove('vision');
                              bloc.add(ToolsetsSelected(next.toList()));
                            },
                    ),
                    if (locked)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          'Kapabilitas dikunci untuk percakapan ini. Mulai chat baru untuk mengubahnya.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    const Divider(height: 8),
                    ListTile(
                      leading: const Icon(ChatIcons.camera),
                      title: const Text('Ambil Foto Kamera'),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickImage(source: ImageSource.camera));
                      },
                    ),
                    ListTile(
                      leading: const Icon(ChatIcons.gallery),
                      title: const Text('Pilih dari Galeri Foto'),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickImage(source: ImageSource.gallery));
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickImage({ImageSource source = ImageSource.gallery}) async {
    if (_pendingImages.length >= _maxPendingImages) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Maksimal 5 gambar per pesan.')),
        );
      return;
    }
    PendingImage? picked;
    try {
      if (widget.pickImage != null) {
        picked = await widget.pickImage!();
      } else {
        final xfile = await ImagePicker().pickImage(
          source: source,
          maxWidth: 2048,
          imageQuality: 85,
        );
        if (xfile == null) return;
        final bytes = await xfile.readAsBytes();
        picked = PendingImage(
          bytes: bytes,
          mimeType: _mimeForPath(xfile.path),
          filename: xfile.name.isEmpty ? 'gambar.jpg' : xfile.name,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Lampiran gagal dibuka.')));
      return;
    }
    if (picked == null) return;
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    setState(() => _pendingImages.add(picked!));
  }

  static String _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  void _removePendingImage(int index) {
    unawaited(HapticFeedback.lightImpact());
    setState(() => _pendingImages.removeAt(index));
  }

  void _submit(BuildContext context) {
    final draft = _draftController.text;
    if (draft.trim().isEmpty && !_hasPendingImages) return;
    unawaited(HapticFeedback.lightImpact());
    context.read<ChatBloc>().add(
      MessageSubmitted(
        draft,
        images: [
          for (final p in _pendingImages)
            ChatImage(
              bytes: p.bytes,
              mimeType: p.mimeType,
              filename: p.filename,
            ),
        ],
      ),
    );
  }

  void _retryMessage(BuildContext context) {
    _scrollToLatest();
    context.read<ChatBloc>().add(const MessageRetried());
  }

  /// Pil model diketuk: lembar pilihan berisi model aktif server dan
  /// daftar dari `GET .../models`.
  void _showModelPicker(BuildContext context, ChatState state) {
    final bloc = context.read<ChatBloc>();
    bloc.add(const ModelsRequested());
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(WangsaRadius.xl),
        ),
      ),
      builder: (sheetContext) => BlocProvider.value(
        value: bloc,
        child: BlocBuilder<ChatBloc, ChatState>(
          builder: (context, currentState) => _ModelPickerSheet(
            state: currentState,
            apiClient: bloc.apiClient,
            onRefreshModels: () {
              bloc.add(const ModelsRequested());
              bloc.add(const SetupStatusRequested());
            },
            onSelected: (model, provider) {
              bloc.add(ModelSelected(model, provider: provider));
              Navigator.of(sheetContext).pop();
            },
          ),
        ),
      ),
    );
  }

  void _scrollToLatest({bool animate = true}) {
    _followLatest = true;
    if (_showLatestButton) setState(() => _showLatestButton = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final latest = _scrollController.position.maxScrollExtent;
      if (!animate) {
        _scrollController.jumpTo(latest);
      } else {
        _scrollController.animateTo(
          latest,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ChatBloc, ChatState>(
      listenWhen: (before, after) => before.isSending && !after.isSending,
      listener: (_, state) {
        final last = state.turns.isEmpty ? null : state.turns.last;
        if (last != null &&
            last.role == TurnRole.agent &&
            state.errorMessage == null) {
          _draftController.clear();
          if (_pendingImages.isNotEmpty) {
            setState(() => _pendingImages.clear());
          }
          unawaited(_speakReply(last.content));
        } else {
          unawaited(widget.voiceInput.endConversation());
        }
      },
      child: _chatConsumer(),
    );
  }

  Future<void> _speakReply(String text) async {
    await widget.voiceInput.speakReply(text);
    if (!mounted) return;
    if (widget.voiceInput.status == VoiceStatus.listening) {
      setState(() {
        _voiceOverlayOpen = true;
        _voiceError = null;
        _voiceStatus = widget.voiceInput.status;
      });
    }
  }

  Widget _chatConsumer() {
    return BlocConsumer<ChatBloc, ChatState>(
      listenWhen: (before, after) =>
          before.turns.length != after.turns.length ||
          before.isSending != after.isSending ||
          before.status != after.status ||
          before.streamingText != after.streamingText ||
          before.toolActivities != after.toolActivities ||
          before.errorMessage != after.errorMessage,
      listener: (context, state) {
        final justSubmitted =
            state.isSending && _lastObservedTurnCount < state.turns.length;
        _lastObservedTurnCount = state.turns.length;
        if (justSubmitted) _followLatest = true;
        if (!_followLatest) {
          if (!_showLatestButton && mounted) {
            setState(() => _showLatestButton = true);
          }
          return;
        }
        _scrollToLatest(animate: !state.isSending);
      },
      builder: (context, state) {
        // Layar chat selalu gelap (keputusan desain, lihat _ChatDark). Tema
        // gelap dipaksa di sini supaya teks balasan/markdown yang memakai
        // ColorScheme ikut terbaca walau pengguna memilih mode Terang —
        // sebelumnya teks #18181B jatuh di atas latar hitam.
        return Theme(
          data: WangsaTheme.forBrightness(Brightness.dark),
          child: Builder(
            builder: (context) => Scaffold(
              key: _scaffoldKey,
              backgroundColor: WangsaGlass.dark.backdropBase,
              drawer: _drawer(context, state),
              body: GlassBackdrop(
                child: SafeArea(
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          _header(context, state),
                          Expanded(child: _content(context, state)),
                        ],
                      ),
                      if (_voiceOverlayOpen) _voiceOverlay(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, ChatState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        children: [
          _circleIconButton(
            icon: ChatIcons.menu,
            tooltip: 'Menu',
            showBadge: true,
            onPressed: () {
              context.read<ChatBloc>().add(const SessionsRequested());
              _scaffoldKey.currentState?.openDrawer();
            },
          ),
          const Spacer(),
          _chatWorkSwitch(context),
          const Spacer(),
          _circleIconButton(
            icon: ChatIcons.newChat,
            tooltip: 'Percakapan baru',
            onPressed: state.status == ChatStatus.ready
                ? () => _startNewConversation(context)
                : null,
          ),
        ],
      ),
    );
  }

  /// Tombol bulat gelap dipakai di header — dua-duanya identik secara
  /// visual (bg abu gelap `_ChatDark.iconCircle`), hanya ikon & aksi
  /// yang beda. Dipisah jadi helper supaya header tetap ringkas dibaca.
  /// [showBadge] menambahkan titik biru kecil di pojok kanan-atas, dipakai
  /// tombol menu sebagai penanda ada sesi/notifikasi baru di drawer.
  Widget _circleIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool showBadge = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 28,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            GlassSurface(
              level: GlassLevel.card,
              borderRadius: BorderRadius.circular(WangsaRadius.pill),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Icon(
                    icon,
                    size: 20,
                    color: onPressed == null
                        ? _ChatDark.hint.withValues(alpha: 0.5)
                        : Colors.white,
                  ),
                ),
              ),
            ),
            if (showBadge)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: _ChatDark.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Segmen pil "Chat" / "Work" di tengah header.
  Widget _chatWorkSwitch(BuildContext context) {
    return GlassSurface(
      level: GlassLevel.card,
      borderRadius: BorderRadius.circular(WangsaRadius.pill),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _switchSegment(label: 'Chat', selected: true, onTap: null),
          _switchSegment(
            label: 'Work',
            selected: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ProductApp(
                  apiBaseUrl: productApiBaseUrl(widget.config.apiBaseUrl),
                  initialToken: widget.auth?.token,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchSegment({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(WangsaRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(WangsaRadius.lg),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : _ChatDark.hint,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _startNewConversation(BuildContext context) {
    unawaited(HapticFeedback.lightImpact());
    context.read<ChatBloc>().add(const ConversationCleared());
  }

  Map<String, List<SessionSummary>> _groupSessions(
    List<SessionSummary> sessions,
  ) {
    final Map<String, List<SessionSummary>> groups = {
      'Hari ini': [],
      'Kemarin': [],
      'Lebih lama': [],
    };
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (final s in sessions) {
      DateTime? dt;
      if (s.updatedAt.isNotEmpty) {
        try {
          dt = DateTime.parse(s.updatedAt).toLocal();
        } catch (_) {}
      }
      if (dt == null) {
        groups['Lebih lama']!.add(s);
      } else {
        final d = DateTime(dt.year, dt.month, dt.day);
        if (d == today) {
          groups['Hari ini']!.add(s);
        } else if (d == yesterday) {
          groups['Kemarin']!.add(s);
        } else {
          groups['Lebih lama']!.add(s);
        }
      }
    }
    return groups;
  }

  Widget _drawer(BuildContext context, ChatState state) {
    const bottomBarHeight = 72.0;
    final sessionGroups = _groupSessions(state.sessions);
    final recentSessions = state.sessions.take(5).toList();
    final hasMore = state.sessions.length > recentSessions.length;

    return Drawer(
      backgroundColor: _ChatDark.drawer,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  8,
                  8,
                  8,
                  bottomBarHeight + 12,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      _drawerHorizontalPadding,
                      4,
                      4,
                      12,
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'Wangsa',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Cari percakapan',
                          icon: const Icon(ChatIcons.search, size: 20),
                          color: _ChatDark.hint,
                          onPressed: () {
                            Navigator.of(context).pop();
                            _openSessionSearch(context, state);
                          },
                        ),
                      ],
                    ),
                  ),
                  _drawerRow(
                    context,
                    ChatIcons.newChat,
                    'Percakapan baru',
                    onTap: state.status == ChatStatus.ready
                        ? () {
                            Navigator.of(context).pop();
                            _startNewConversation(context);
                          }
                        : null,
                  ),
                  _drawerRow(
                    context,
                    ChatIcons.agent,
                    'Bangun Agent',
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const AgentBuilderPage(),
                        ),
                      );
                    },
                  ),
                  _modelDrawerRow(context, state),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(
                      _drawerHorizontalPadding,
                      12,
                      _drawerHorizontalPadding,
                      8,
                    ),
                    child: Divider(height: 1, color: _ChatDark.groupBorder),
                  ),
                  if (state.isLoadingSessions) ...[
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ] else if (state.sessions.isEmpty) ...[
                    _drawerSectionHeader(context, 'Riwayat Percakapan'),
                    _drawerEmptyNote(context, 'Belum ada riwayat percakapan'),
                  ] else ...[
                    for (final session in recentSessions)
                      _sessionRow(context, state, session),
                    if (hasMore)
                      InkWell(
                        borderRadius: BorderRadius.circular(WangsaRadius.sm),
                        onTap: () {
                          Navigator.of(context).pop();
                          _openAllSessions(context, state, sessionGroups);
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: _drawerHorizontalPadding,
                            vertical: 10,
                          ),
                          child: Text(
                            'Lihat semua',
                            style: TextStyle(
                              color: _ChatDark.hint,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomBarHeight,
              height: 28,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _ChatDark.drawer.withValues(alpha: 0),
                        _ChatDark.drawer,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottomBarHeight,
              child: ColoredBox(
                color: _ChatDark.drawer,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: FilledButton.icon(
                            onPressed: state.status == ChatStatus.ready
                                ? () {
                                    Navigator.of(context).pop();
                                    _startNewConversation(context);
                                  }
                                : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: _ChatDark.accent,
                              foregroundColor: Colors.white,
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(ChatIcons.newChat, size: 18),
                            label: const Text(
                              'Chat',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Satu pintu untuk profil + pengaturan: aplikasi belum punya
                      // sistem akun, jadi keduanya digabung di SettingsPage.
                      _circleIconButton(
                        icon: ChatIcons.profile,
                        tooltip: 'Profil & pengaturan',
                        onPressed: () {
                          Navigator.of(context).pop();
                          _openSettings(context);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Pencarian sesi sederhana: dibuka dari ikon kaca pembesar di header
  /// drawer, filter langsung dari [ChatState.sessions] yang sudah dimuat
  /// (tidak ada endpoint pencarian server tersendiri).
  void _openSessionSearch(BuildContext context, ChatState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        var query = '';
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final filtered = query.isEmpty
                ? state.sessions
                : state.sessions
                      .where(
                        (s) =>
                            s.title.toLowerCase().contains(query.toLowerCase()),
                      )
                      .toList();
            return GlassSheetSurface(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Cari percakapan',
                        hintStyle: TextStyle(color: _ChatDark.hint),
                        prefixIcon: Icon(
                          ChatIcons.search,
                          color: _ChatDark.hint,
                        ),
                        filled: true,
                        fillColor: _ChatDark.pill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(
                            Radius.circular(WangsaRadius.sm),
                          ),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (value) => setSheetState(() => query = value),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.of(sheetContext).size.height * 0.5,
                      ),
                      child: filtered.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                'Tidak ada percakapan yang cocok.',
                                style: TextStyle(color: _ChatDark.hint),
                              ),
                            )
                          : ListView(
                              shrinkWrap: true,
                              children: [
                                for (final session in filtered)
                                  _sessionRow(sheetContext, state, session),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Daftar lengkap riwayat percakapan (dikelompokkan per tanggal), dibuka
  /// dari "Lihat semua..." saat drawer hanya menampilkan 5 sesi terbaru.
  void _openAllSessions(
    BuildContext context,
    ChatState state,
    Map<String, List<SessionSummary>> sessionGroups,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetContext, scrollController) => GlassSheetSurface(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            children: [
              for (final entry in sessionGroups.entries)
                if (entry.value.isNotEmpty) ...[
                  _drawerSectionHeader(sheetContext, entry.key),
                  for (final session in entry.value)
                    _sessionRow(sheetContext, state, session),
                ],
            ],
          ),
        ),
      ),
    );
  }

  /// Baris model di drawer — pindahan dari pil composer (keputusan
  /// pengguna: composer disederhanakan jadi 1 baris ala referensi
  /// Figma, jadi pemilihan model dipindah ke sini).
  Widget _modelDrawerRow(BuildContext context, ChatState state) {
    return _drawerRow(
      context,
      ChatIcons.model,
      'Model',
      value: state.effectiveModel ?? state.agent?.name ?? 'Wangsa',
      onTap: () {
        Navigator.of(context).pop();
        _showModelPicker(context, state);
      },
    );
  }

  Widget _sessionRow(
    BuildContext context,
    ChatState state,
    SessionSummary session,
  ) {
    final isSelected = state.sessionId == session.sessionId;
    return InkWell(
      borderRadius: BorderRadius.circular(WangsaRadius.sm),
      onTap: () {
        Navigator.of(context).pop();
        context.read<ChatBloc>().add(SessionSelected(session.sessionId));
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.only(
          left: _drawerHorizontalPadding,
          right: 4,
        ),
        decoration: BoxDecoration(
          color: isSelected ? _ChatDark.rowSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(WangsaRadius.sm),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                session.title.isNotEmpty ? session.title : 'Percakapan',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _drawerLabelStyle,
              ),
            ),
            IconButton(
              icon: const Icon(ChatIcons.delete, size: 16),
              tooltip: 'Hapus sesi',
              color: _ChatDark.hint.withValues(alpha: 0.6),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                context.read<ChatBloc>().add(SessionDeleted(session.sessionId));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, ChatState state) {
    if (state.status == ChatStatus.loading ||
        state.status == ChatStatus.initial) {
      return Center(
        child: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );
    }

    if (state.status == ChatStatus.notFound) {
      return ChatNotice.notFound(extra: _fallbackConfigNotice());
    }
    if (state.status == ChatStatus.failed) {
      return ChatNotice.failed(
        detail: state.errorMessage ?? 'Tidak bisa menghubungi API Wangsa.',
        extra: _fallbackConfigNotice(),
      );
    }

    return _chatConversation(context, state);
  }

  Widget? _fallbackConfigNotice() {
    final problem = widget.configProblem;
    if (problem == null) return null;
    return FallbackConfigNotice(
      problem: problem,
      apiBaseUrl: widget.config.apiBaseUrl,
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          config: _activeConfig,
          configProblem: widget.configProblem,
          agentId: context.read<ChatBloc>().agentId,
          voiceInput: widget.voiceInput,
          themeController: widget.themeController,
          llmSettings: widget.llmSettings,
          userProfile: widget.userProfile,
          agent: context.read<ChatBloc>().state.agent,
          apiClient: context.read<ChatBloc>().apiClient,
          auth: widget.auth,
          onApiBaseUrlChanged: (newUrl) {
            setState(() {
              _activeConfig = _activeConfig.copyWith(apiBaseUrl: newUrl);
            });
            context.read<ChatBloc>().add(ApiBaseUrlChanged(newUrl));
            widget.onApiBaseUrlChanged?.call(newUrl);
          },
        ),
      ),
    );
  }

  /// Keluar dari banner sesi-berakhir: cabut token (best-effort) lalu hapus
  /// sesi lokal — AuthGate rebuild ke layar daftar/masuk.
  Future<void> _signOut(BuildContext context) async {
    final bloc = context.read<ChatBloc>();
    try {
      await bloc.apiClient.revokeToken();
    } catch (_) {
      // Abaikan — sesi lokal tetap dibersihkan.
    }
    bloc.apiClient.updateToken(null);
    await widget.auth?.clear();
  }

  String _budgetLine(ChatState state) {
    final b = state.budget;
    if (b == null) return '';
    final parts = <String>[];
    if (b.dailyUsd != null) {
      parts.add(
        'harian \$${b.spentDay.toStringAsFixed(2)} / \$${b.dailyUsd!.toStringAsFixed(2)}',
      );
    }
    if (b.monthlyUsd != null) {
      parts.add(
        'bulanan \$${b.spentMonth.toStringAsFixed(2)} / \$${b.monthlyUsd!.toStringAsFixed(2)}',
      );
    }
    if (parts.isEmpty) return '';
    return parts.join(' • ');
  }

  static const _composerReserve = 160.0;

  Widget _chatConversation(BuildContext context, ChatState state) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: state.turns.isEmpty
              ? (state.isLoadingHistory
                    ? const Center(child: CircularProgressIndicator())
                    : ChatNotice.empty())
              : ShaderMask(
                  shaderCallback: (Rect bounds) {
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      // Hanya fade sisi atas. Sisi bawah dibiarkan penuh agar
                      // pesan yang bergulir di belakang composer kaca tetap
                      // ada untuk di-blur (sebelumnya memudar sampai nol).
                      colors: [Colors.transparent, Colors.black],
                      stops: [0.0, 0.05],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(
                      20,
                      16,
                      20,
                      _composerReserve,
                    ),
                    itemCount: state.turns.length + (state.isSending ? 1 : 0),
                    itemBuilder: (_, index) {
                      if (index == state.turns.length) {
                        if (state.streamingText.isNotEmpty) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (state.currentActivity != null)
                                ThinkingIndicator(
                                  activity: state.currentActivity,
                                  activities: state.toolActivities,
                                  isWaitingForReply:
                                      state.streamingText.isEmpty,
                                ),
                              MessageBubble(
                                turn: Turn(
                                  role: TurnRole.agent,
                                  content: state.streamingText,
                                  isStreaming: true,
                                ),
                                onSpeak: (text) =>
                                    widget.voiceInput.readAloud(text),
                                onFollowUp: (text) => context
                                    .read<ChatBloc>()
                                    .add(MessageSubmitted(text)),
                              ),
                            ],
                          );
                        }
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: ThinkingIndicator(
                            activity: state.currentActivity,
                            activities: state.toolActivities,
                            isWaitingForReply: true,
                          ),
                        );
                      }
                      return MessageBubble(
                        turn: state.turns[index],
                        onSpeak: (text) => widget.voiceInput.readAloud(text),
                        onFollowUp: (text) => context.read<ChatBloc>().add(
                          MessageSubmitted(text),
                        ),
                      );
                    },
                  ),
                ),
        ),
        if (_showLatestButton && state.turns.isNotEmpty)
          Positioned(
            right: 16,
            bottom: _composerReserve - 2,
            child: Semantics(
              button: true,
              label: 'Ke pesan terbaru',
              child: IconButton.filledTonal(
                tooltip: 'Ke pesan terbaru',
                onPressed: () => _scrollToLatest(),
                icon: const Icon(ChatIcons.latest),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.authInvalid)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(WangsaRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Sesi berakhir.',
                        style: TextStyle(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Token tidak dikenali server (mungkin dicabut). Keluar lalu daftar/masuk lagi.',
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        icon: const Icon(ChatIcons.signOut, size: 18),
                        label: const Text('Keluar'),
                        onPressed: () => _signOut(context),
                      ),
                    ],
                  ),
                ),
              if (state.budget?.isBreached == true)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(WangsaRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Budget tercapai — chat dijeda.',
                        style: TextStyle(
                          color: scheme.onErrorContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _budgetLine(state),
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        icon: const Icon(ChatIcons.usage, size: 18),
                        label: const Text('Lihat pemakaian'),
                        onPressed: () => _openSettings(context),
                      ),
                    ],
                  ),
                )
              else if ((state.budget?.alert == true) &&
                  state.budget?.hasCap == true)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(WangsaRadius.md),
                  ),
                  child: Text(
                    'Pemakaian mendekati batas: ${_budgetLine(state)}',
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
              if (state.needsSetup)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(WangsaRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.profileName != null &&
                                state.profileName!.isNotEmpty
                            ? 'Halo ${state.profileName}! Hubungkan LLM milikmu dulu.'
                            : 'Hubungkan LLM milikmu dulu.',
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Satu akun = satu profile terisolasi. Pilih provider yang kamu punya, simpan kuncinya, lalu mulai chat.',
                        style: TextStyle(color: scheme.onPrimaryContainer),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        icon: const Icon(ChatIcons.key, size: 18),
                        label: state.isCheckingSetup
                            ? const Text('Memeriksa…')
                            : const Text('Setup Provider'),
                        onPressed: state.isCheckingSetup
                            ? null
                            : () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ProviderSetupPage(
                                      apiClient: context
                                          .read<ChatBloc>()
                                          .apiClient,
                                      onCredentialsChanged: () {
                                        context.read<ChatBloc>().add(
                                          const ModelsRequested(),
                                        );
                                      },
                                    ),
                                  ),
                                );
                                if (!context.mounted) return;
                                context.read<ChatBloc>().add(
                                  const SetupStatusRequested(),
                                );
                              },
                      ),
                    ],
                  ),
                ),
              if (state.errorMessage != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(WangsaRadius.md),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.errorMessage!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                      if (state.canRetry)
                        TextButton.icon(
                          onPressed: () => _retryMessage(context),
                          icon: const Icon(ChatIcons.refresh, size: 18),
                          label: const Text('Coba lagi'),
                        ),
                    ],
                  ),
                ),
              _commandSuggester(context),
              _messageComposer(context, state),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }

  Widget _commandSuggester(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _draftController,
      builder: (context, value, _) {
        final text = value.text.trim();
        if (!text.startsWith('/')) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final filtered = _slashCommands
            .where((c) => c['command']!.startsWith(text.toLowerCase()))
            .toList();
        if (filtered.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(WangsaRadius.md),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WangsaRadius.md),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: filtered.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.2),
              ),
              itemBuilder: (context, index) {
                final item = filtered[index];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    ChatIcons.tool,
                    size: 18,
                    color: scheme.primary,
                  ),
                  title: Text(
                    item['command']!,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    item['desc']!,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () {
                    unawaited(HapticFeedback.lightImpact());
                    _draftController.text = item['command']!;
                    _draftController.selection = TextSelection.fromPosition(
                      TextPosition(offset: _draftController.text.length),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _messageComposer(BuildContext context, ChatState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: GlassSurface(
        level: GlassLevel.bar,
        borderRadius: BorderRadius.circular(28),
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_hasPendingImages) _pendingStrip(),
            if (state.selectedToolsets.isNotEmpty) _toolsetChipsRow(state),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: state.isSending
                      ? null
                      : () => unawaited(_showAttachmentPicker()),
                  tooltip: 'Lampiran',
                  icon: const Icon(ChatIcons.attach),
                  color: Colors.white,
                ),
                Expanded(
                  child: TextField(
                    controller: _draftController,
                    enabled: !state.isSending,
                    minLines: 1,
                    maxLines: 4,
                    onSubmitted: (_) => _submit(context),
                    decoration: InputDecoration(
                      hintText: 'Tulis pesan untuk Wangsa',
                      hintStyle: const TextStyle(
                        color: _ChatDark.hint,
                        fontWeight: FontWeight.w400,
                      ),
                      filled: false,
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                const SizedBox(width: 4),
                if (!state.isSending)
                  IconButton(
                    onPressed: () => unawaited(_toggleListening()),
                    tooltip: _isListening
                        ? 'Berhenti mendengar'
                        : 'Dikte suara',
                    icon: Icon(
                      _isListening ? ChatIcons.stop : ChatIcons.microphone,
                    ),
                    color: Colors.white,
                  ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _draftController,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    final canSend = hasText || _hasPendingImages;
                    if (state.isSending) {
                      return _composerCircleButton(
                        icon: ChatIcons.stop,
                        tooltip: 'Berhenti',
                        onPressed: () => context.read<ChatBloc>().add(
                          const MessageCancelled(),
                        ),
                      );
                    }
                    if (canSend) {
                      return _composerCircleButton(
                        icon: ChatIcons.send,
                        tooltip: 'Kirim',
                        onPressed: () => _submit(context),
                      );
                    }
                    return _composerCircleButton(
                      icon: ChatIcons.voice,
                      tooltip: 'Bicara',
                      onPressed: () => unawaited(_toggleListening()),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tombol bulat biru di ujung kanan composer — dipakai untuk suara,
  /// kirim, dan berhenti (ikon berganti sesuai `state.isSending` dan isi
  /// draft). Warna solid biru meniru tombol "Voice" pada referensi desain.
  Widget _composerCircleButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 26,
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: _ChatDark.accent,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }

  Widget _toolsetChipsRow(ChatState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Wrap(
        spacing: 6,
        children: [
          for (final toolset in state.selectedToolsets)
            Chip(
              visualDensity: VisualDensity.compact,
              backgroundColor: _ChatDark.pill,
              side: BorderSide.none,
              label: Text(
                toolset == 'web' ? 'Web' : 'Analisis gambar',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              avatar: Icon(
                toolset == 'web' ? ChatIcons.web : ChatIcons.image,
                size: 16,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  Widget _pendingStrip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingImages.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, index) {
            final img = _pendingImages[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(WangsaRadius.sm),
                  child: Image.memory(
                    img.bytes,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 64,
                      height: 64,
                      color: _ChatDark.pill,
                      child: const Icon(
                        ChatIcons.brokenImage,
                        color: _ChatDark.hint,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onTap: () => _removePendingImage(index),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        ChatIcons.close,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static const _drawerRowHeight = 48.0;
  static const _drawerHorizontalPadding = 16.0;
  static const _drawerLabelStyle = TextStyle(
    color: Colors.white,
    fontSize: 16,
    fontWeight: FontWeight.w400,
  );

  /// Baris fitur sidebar: ikon garis tipis + label, rata, tanpa kartu.
  Widget _drawerRow(
    BuildContext context,
    IconData icon,
    String label, {
    String? value,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    final color = enabled
        ? Colors.white
        : _ChatDark.hint.withValues(alpha: 0.5);
    return InkWell(
      borderRadius: BorderRadius.circular(WangsaRadius.sm),
      onTap: onTap,
      child: SizedBox(
        height: _drawerRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _drawerHorizontalPadding,
          ),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _drawerLabelStyle.copyWith(color: color),
                ),
              ),
              // Nilai (mis. nama model) dibatasi lebarnya supaya label
              // selalu mendapat ruang lebih dulu; nama panjang disingkat.
              if (value != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _ChatDark.hint, fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drawerSectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _drawerHorizontalPadding,
        20,
        _drawerHorizontalPadding,
        6,
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: _ChatDark.hint,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _drawerEmptyNote(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _drawerHorizontalPadding,
        vertical: 4,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: _ChatDark.hint.withValues(alpha: 0.85),
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _voiceOverlay(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => unawaited(_cancelVoiceOverlay()),
        child: GlassScrim(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VoiceOrb(
                    status: _voiceStatus,
                    level: _soundLevel,
                    hasError: _voiceError != null,
                    size: 140,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _statusLine(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_voiceError == null &&
                      _isListening &&
                      _draftController.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        _draftController.text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  if (_voiceError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        _voiceError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.red.shade200,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => unawaited(_cancelVoiceOverlay()),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: Text(_voiceError != null ? 'Tutup' : 'Batal'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _statusLine() {
    if (_voiceError != null) return 'Suara tidak tersedia';
    switch (_voiceStatus) {
      case VoiceStatus.off:
        return 'Siap';
      case VoiceStatus.idle:
        return 'Siaga kata pemicu';
      case VoiceStatus.listening:
        return 'Mendengarkan...';
      case VoiceStatus.processing:
        return 'Merapikan ucapan...';
    }
  }
}

class _ModelPickerCandidate {
  final String model;
  final String providerId;
  final String providerName;

  const _ModelPickerCandidate({
    required this.model,
    required this.providerId,
    required this.providerName,
  });
}

class _ModelPickerSheet extends StatefulWidget {
  final ChatState state;
  final WangsaApiClient apiClient;
  final VoidCallback? onRefreshModels;
  final void Function(String? model, String? provider) onSelected;

  const _ModelPickerSheet({
    required this.state,
    required this.apiClient,
    this.onRefreshModels,
    required this.onSelected,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  String? _selectedProviderId;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    final provider = widget.state.effectiveProvider;
    _selectedProviderId = provider == null || provider.isEmpty
        ? null
        : provider;
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_ModelPickerCandidate> _getCandidates() {
    final List<_ModelPickerCandidate> candidates = [];
    final providers = widget.state.providers;

    if (providers.isNotEmpty) {
      for (final p in providers) {
        if (_selectedProviderId != null && p.id != _selectedProviderId) {
          continue;
        }
        for (final m in p.models) {
          if (_searchQuery.isEmpty || m.toLowerCase().contains(_searchQuery)) {
            candidates.add(
              _ModelPickerCandidate(
                model: m,
                providerId: p.id,
                providerName: p.name,
              ),
            );
          }
        }
      }
    } else {
      for (final m in widget.state.models) {
        if (_searchQuery.isEmpty || m.toLowerCase().contains(_searchQuery)) {
          candidates.add(
            _ModelPickerCandidate(
              model: m,
              providerId: widget.state.currentProvider ?? "",
              providerName: widget.state.currentProvider ?? "Default",
            ),
          );
        }
      }
    }
    return candidates;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = widget.state;
    final candidates = _getCandidates();
    final providers = state.providers;

    final isDefaultSelected = state.selectedModel == null;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "Pilih Provider & Model",
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(ChatIcons.tune, size: 18),
                    label: const Text(
                      "Setup Provider",
                      style: TextStyle(fontSize: 12),
                    ),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ProviderSetupPage(
                            apiClient: widget.apiClient,
                            onCredentialsChanged: () {
                              widget.onRefreshModels?.call();
                            },
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(ChatIcons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: "Cari nama model...",
                  prefixIcon: const Icon(ChatIcons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(ChatIcons.close),
                          onPressed: () => _searchController.clear(),
                        )
                      : null,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(WangsaRadius.sm),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (providers.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text("Semua"),
                      selected: _selectedProviderId == null,
                      onSelected: (selected) {
                        setState(() {
                          _selectedProviderId = null;
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    for (final p in providers.where(
                      (p) => p.models.isNotEmpty,
                    )) ...[
                      FilterChip(
                        label: Text("${p.name} (${p.models.length})"),
                        selected: _selectedProviderId == p.id,
                        onSelected: (selected) {
                          setState(() {
                            _selectedProviderId = selected ? p.id : null;
                          });
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: state.isLoadingModels
                  ? const Center(child: CircularProgressIndicator())
                  : state.modelsError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(ChatIcons.offline, size: 36),
                            const SizedBox(height: 12),
                            Text(
                              state.modelsError!,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: widget.onRefreshModels,
                              icon: const Icon(ChatIcons.refresh),
                              label: const Text('Coba lagi'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: candidates.isEmpty ? 2 : candidates.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 1 &&
                            candidates.isEmpty &&
                            _selectedProviderId == null) {
                          return Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  ChatIcons.tune,
                                  size: 32,
                                  color: scheme.primary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Belum ada model yang bisa dipilih. Chat tetap memakai bawaan deployment.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextButton.icon(
                                  onPressed: widget.onRefreshModels,
                                  icon: const Icon(ChatIcons.refresh),
                                  label: const Text('Coba lagi'),
                                ),
                              ],
                            ),
                          );
                        }
                        if (index == 1 &&
                            candidates.isEmpty &&
                            _selectedProviderId != null) {
                          return Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  ChatIcons.key,
                                  size: 40,
                                  color: scheme.primary,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  "Provider \"$_selectedProviderId\" belum terkonfigurasi atau belum memiliki model aktif.",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  icon: const Icon(ChatIcons.signIn, size: 16),
                                  label: Text("Hubungkan $_selectedProviderId"),
                                  onPressed: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ProviderSetupPage(
                                          apiClient: widget.apiClient,
                                          onCredentialsChanged: () {
                                            widget.onRefreshModels?.call();
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          );
                        }
                        if (index == 0) {
                          final defaultSubtitle = [
                            if (state.currentProvider != null &&
                                state.currentProvider!.isNotEmpty)
                              "Provider: ${state.currentProvider}",
                            if (state.currentModel != null &&
                                state.currentModel!.isNotEmpty)
                              "Model: ${state.currentModel}",
                          ].join(" • ");

                          return ListTile(
                            leading: const Icon(ChatIcons.tool),
                            title: const Text(
                              "Bawaan deployment",
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: defaultSubtitle.isNotEmpty
                                ? Text(
                                    defaultSubtitle,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  )
                                : null,
                            trailing: isDefaultSelected
                                ? Icon(ChatIcons.check, color: scheme.primary)
                                : null,
                            onTap: () => widget.onSelected(null, null),
                          );
                        }

                        final item = candidates[index - 1];
                        final isSelected =
                            !isDefaultSelected &&
                            item.model == state.effectiveModel &&
                            (item.providerId == state.effectiveProvider ||
                                state.effectiveProvider == null);

                        return ListTile(
                          title: Text(
                            item.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            item.providerName,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: isSelected
                              ? Icon(ChatIcons.check, color: scheme.primary)
                              : null,
                          onTap: () =>
                              widget.onSelected(item.model, item.providerId),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
