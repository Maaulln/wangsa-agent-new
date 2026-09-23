import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/models.dart';
import '../../config/app_config.dart';
import '../../llm/llm_settings_controller.dart';
import '../../profile/view/profile_page.dart';
import '../../settings/view/settings_page.dart';
import '../../theme/theme_controller.dart';
import '../../voice/voice_input.dart';
import '../bloc/chat_bloc.dart';
import 'message_bubble.dart';
import 'widgets/chat_notice.dart';
import 'widgets/thinking_indicator.dart';
import 'widgets/voice_orb.dart';

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
/// layar ini tetap hanya mengenal kontrak [VoiceInput], sehingga wake
/// word Porcupine milik Irawan tetap yang menyala di baliknya.
class ChatPage extends StatefulWidget {
  final AppConfig config;
  final String? configProblem;

  /// Satu instance dipegang bersama sepanjang umur aplikasi (lihat
  /// main.dart) — layar chat memegangnya, dan mengopernya lagi ke
  /// [SettingsPage] saat pengguna membuka layar itu, supaya sakelar
  /// "dengar di latar belakang" di sana mengendalikan mesin yang sama,
  /// bukan instance baru.
  final VoiceInput voiceInput;

  /// Diteruskan apa adanya ke [SettingsPage] — lihat catatan di
  /// theme_controller.dart soal kenapa ini perlu ada sama sekali.
  final ThemeController themeController;

  /// Diteruskan apa adanya ke [SettingsPage] untuk formulir kunci API
  /// LLM (BYOK).
  final LlmSettingsController llmSettings;

  /// Penyuntikan pemilih gambar untuk test — produksi memakai galeri
  /// sistem lewat `image_picker`. Mengembalikan null bila pengguna
  /// membatalkan.
  final Future<PendingImage?> Function()? pickImage;

  const ChatPage({
    super.key,
    required this.config,
    required this.voiceInput,
    required this.themeController,
    required this.llmSettings,
    this.configProblem,
    this.pickImage,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _draftController = TextEditingController();
  final _scrollController = ScrollController();
  late final AnimationController _waveController;
  StreamSubscription<VoiceEvent>? _voiceSubscription;
  VoiceStatus _voiceStatus = VoiceStatus.off;

  /// Lapisan suara sedang menimpa layar chat. Terpisah dari [_voiceStatus]
  /// dengan sengaja: status "idle" (siaga kata pemicu) tidak boleh
  /// menampilkan lapisan ini, hanya "listening"/"processing", atau saat
  /// ada galat yang perlu dibaca pengguna.
  bool _voiceOverlayOpen = false;
  String? _voiceError;

  /// Level volume mikrofon terkini, 0.0-1.0 — lihat `SoundLevelChanged`
  /// di voice_input.dart. Cuma dipakai `VoiceOrb`, direset ke 0 setiap
  /// sesi dengar berakhir supaya orb tidak "membeku" di ukuran terakhir.
  double _soundLevel = 0;

  bool get _isListening => _voiceStatus == VoiceStatus.listening;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _voiceStatus = widget.voiceInput.status;
    _voiceSubscription = widget.voiceInput.events.listen(_onVoiceEvent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waveController.dispose();
    _voiceSubscription?.cancel();
    // Layar ini adalah satu-satunya pemilik VoiceInput (lihat main.dart),
    // jadi ia juga yang bertanggung jawab melepaskannya.
    widget.voiceInput.dispose();
    _draftController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // DESIGN.md §15/16: tidak ada animasi tanpa tujuan, dan pengguna yang
    // meminta gerak berkurang di sistemnya harus benar-benar dituruti.
    if (MediaQuery.of(context).disableAnimations) {
      _waveController.stop();
    } else if (!_waveController.isAnimating) {
      _waveController.repeat();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty && views.first.viewInsets.bottom > 0) {
      _scrollToLatest();
    }
  }

  /// Menerjemahkan kejadian dari lapisan suara menjadi perubahan pada
  /// layar ini. Layar tidak pernah tahu ada Porcupine atau
  /// `speech_to_text` di baliknya — hanya empat jenis [VoiceEvent] ini,
  /// persis batas yang didokumentasikan di voice_input.dart.
  void _onVoiceEvent(VoiceEvent event) {
    switch (event) {
      case WakeWordDetected():
        setState(() {
          _voiceOverlayOpen = true;
          _voiceError = null;
          _voiceStatus = widget.voiceInput.status;
        });
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Wake word "${widget.config.wakeWord}" terdeteksi.')),
          );
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

  Future<void> _pickImage() async {
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
          source: ImageSource.gallery,
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
        ..showSnackBar(
          const SnackBar(content: Text('Lampiran gagal dibuka.')),
        );
      return;
    }
    if (picked == null) return;
    if (!mounted) return;
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
    setState(() => _pendingImages.removeAt(index));
  }

  void _submit(BuildContext context) {
    final draft = _draftController.text;
    if (draft.trim().isEmpty && !_hasPendingImages) return;
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
    _draftController.clear();
    setState(() => _pendingImages.clear());
  }

  /// Pil model diketuk: lembar pilihan berisi model aktif server dan
  /// daftar dari `GET .../models`. Pilihan disimpan di [ChatBloc]
  /// ([ModelSelected]) dan dikirim bersama setiap pesan berikutnya.
  void _showModelPicker(BuildContext context, ChatState state) {
    if (state.models.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Daftar model belum tersedia.')),
        );
      return;
    }
    final effective = state.effectiveModel;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                state.currentModel == null
                    ? 'Bawaan deployment'
                    : 'Bawaan (${state.currentModel})',
              ),
              trailing: effective == state.currentModel || state.selectedModel == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () {
                context.read<ChatBloc>().add(const ModelSelected(null));
                Navigator.of(sheetContext).pop();
              },
            ),
            const Divider(height: 1),
            for (final model in state.models)
              ListTile(
                title: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: model == effective
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  context.read<ChatBloc>().add(ModelSelected(model));
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ChatBloc, ChatState>(
      // Agent selesai menanggapi ucapan: berhasil, gagal, atau dibatalkan.
      // Lapisan suara yang menentukan apakah balasannya dibacakan (hanya
      // untuk percakapan suara), layar cukup melaporkan hasilnya.
      listenWhen: (before, after) => before.isSending && !after.isSending,
      listener: (_, state) {
        final last = state.turns.isEmpty ? null : state.turns.last;
        if (last != null && last.role == TurnRole.agent) {
          unawaited(_speakReply(last.content));
        } else {
          unawaited(widget.voiceInput.endConversation());
        }
      },
      child: _chatConsumer(),
    );
  }

  /// Membacakan [text] lewat lapisan suara. Ia kembali setelah mikrofon
  /// lanjutan menyala, jadi saat itu lapisan dibuka lagi supaya pengguna
  /// tahu mikrofon sedang mendengar.
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
          before.status != after.status,
      listener: (_, state) {
        _scrollToLatest();
      },
      builder: (context, state) {
        return Scaffold(
          key: _scaffoldKey,
          drawer: _drawer(context, state),
          body: SafeArea(
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
        );
      },
    );
  }

  /// Header ala Gemini/Claude: hamburger di kiri membuka [_drawer], pensil
  /// di kanan langsung memulai percakapan baru. Wordmark Wangsa sengaja
  /// dikosongkan dulu di sini, bukan dihapus permanen — lihat catatan di
  /// [_drawer] soal arah jangka panjangnya.
  Widget _header(BuildContext context, ChatState state) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            tooltip: 'Menu',
            icon: const Icon(Icons.menu_rounded, size: 24),
            color: scheme.onSurfaceVariant,
          ),
          const Spacer(),
          IconButton(
            onPressed: state.status == ChatStatus.ready
                ? () => _startNewConversation(context)
                : null,
            tooltip: 'Percakapan baru',
            icon: const Icon(Icons.edit_square, size: 22),
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  void _startNewConversation(BuildContext context) {
    context.read<ChatBloc>().add(const ConversationCleared());
  }

  /// Isi laci: satu aksi nyata di daftar atas (percakapan baru, mengosongkan
  /// giliran di memori), dan bilah bawah TETAP — tidak ikut scroll, ala
  /// ChatGPT — berisi jalan pintas ke Profil (avatar) dan Pengaturan
  /// (gear). Keduanya langsung satu ketukan, sengaja TIDAK disembunyikan
  /// di balik menu akun, karena Wangsa belum punya sistem akun untuk
  /// membenarkan menu semacam itu. Kabut tipis di atas bilah bawah murni
  /// dekoratif (`IgnorePointer`, tidak mencegat ketukan) supaya daftar
  /// yang di-scroll melebur ke bilah bawah alih-alih terpotong tiba-tiba.
  ///
  /// BUKAN daftar riwayat percakapan/projek/plugin ala ChatGPT/Gemini —
  /// itu arah yang diminta, tapi menuntut penyimpanan multi-percakapan di
  /// backend yang belum ada. Menambahnya sebagai tombol di sini sekarang
  /// berarti tombol yang berpura-pura berfungsi, jadi sengaja ditunda
  /// sampai backend-nya nyata.
  Widget _drawer(BuildContext context, ChatState state) {
    final scheme = Theme.of(context).colorScheme;
    const bottomBarHeight = 72.0;
    return Drawer(
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, bottomBarHeight + 12),
                children: [
                  _drawerRow(
                    context,
                    Icons.edit_square,
                    'Percakapan baru',
                    onTap: state.status == ChatStatus.ready
                        ? () {
                            Navigator.of(context).pop();
                            _startNewConversation(context);
                          }
                        : null,
                  ),
                  // Placeholder ala sidebar ChatGPT — SEMUA di bawah ini
                  // belum punya backend (lihat catatan di atas) dan
                  // ditandai "Segera", bukan pura-pura berfungsi. Diketuk
                  // hanya memunculkan info "belum tersedia".
                  _drawerPlaceholder(context, Icons.collections_bookmark_outlined, 'Pustaka'),
                  _drawerPlaceholder(context, Icons.folder_outlined, 'Proyek'),
                  _drawerPlaceholder(context, Icons.schedule_outlined, 'Terjadwal'),
                  _drawerPlaceholder(context, Icons.extension_outlined, 'Plugin'),
                  _drawerSectionHeader(context, 'Disematkan'),
                  _drawerEmptyNote(context, 'Belum ada percakapan yang disematkan'),
                  _drawerSectionHeader(context, 'Terbaru'),
                  _drawerEmptyNote(context, 'Riwayat percakapan segera hadir'),
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
                        scheme.surface.withValues(alpha: 0),
                        scheme.surface,
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
                color: scheme.surface,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(24),
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ProfilePage(agent: state.agent),
                              ),
                            );
                          },
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: scheme.primaryContainer,
                                child: Icon(
                                  Icons.person_outline,
                                  size: 20,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Profil',
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Pengaturan',
                        icon: const Icon(Icons.settings_outlined),
                        color: scheme.onSurfaceVariant,
                        onPressed: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SettingsPage(
                                config: widget.config,
                                configProblem: widget.configProblem,
                                agentId: context.read<ChatBloc>().agentId,
                                voiceInput: widget.voiceInput,
                                themeController: widget.themeController,
                                llmSettings: widget.llmSettings,
                              ),
                            ),
                          );
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

  Widget _content(BuildContext context, ChatState state) {
    if (state.status == ChatStatus.loading ||
        state.status == ChatStatus.initial) {
      return Center(
        child: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );
    }

    // ChatNotice sudah membawa blok "Memakai konfigurasi cadangan"
    // (lihat widgets/chat_notice.dart) — dipertahankan dari layar lama
    // ini, bukan bawaan Yardan, karena itu yang membuat kegagalan
    // konfigurasi bisa dikenali dalam hitungan detik, bukan lewat
    // penyelidikan panjang.
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

  /// Daftar chat mengisi seluruh tinggi layar, bukan berhenti sebelum
  /// komposer — komposer melayang DI ATASNYA lewat `Positioned`, dengan
  /// kaca buram (`BackdropFilter`) supaya pesan yang lewat di baliknya
  /// tetap terlihat samar-samar, bukan tertutup kotak solid. Padding
  /// bawah daftar ([_composerReserve]) menyisakan ruang supaya pesan
  /// terakhir tidak sungguhan tertutup komposer saat discroll ke ujung.
  ///
  /// 160, bukan sekadar tinggi composer satu baris (~126 — lihat
  /// `_messageComposer`: padding luar 14 + kartu 18 + TextField ~24 +
  /// jarak 10 + baris ikon ~48 + `SizedBox` 12 di bawahnya), supaya masih
  /// ada napas walau composer tumbuh dua baris teks. Nilai yang lebih
  /// kecil sebelumnya (100) membuat item terakhir separuh ketiban lapisan
  /// buram, terlihat "bentrok" alih-alih berhenti bersih di atasnya.
  static const _composerReserve = 160.0;

  Widget _chatConversation(BuildContext context, ChatState state) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: state.turns.isEmpty
              ? ChatNotice.empty()
              : ShaderMask(
                  shaderCallback: (Rect bounds) {
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.06, 0.78, 0.95],
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
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: ThinkingIndicator(
                            avatarAnimation: _waveController,
                          ),
                        );
                      }
                      return MessageBubble(turn: state.turns[index]);
                    },
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
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    state.errorMessage!,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              _messageComposer(context, state),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }

  /// Kartu dua baris ala Claude: teks di atas, ikon di bawah. `+`
  /// membuka galeri sistem (gambar dikirim sebagai lampiran yang bisa
  /// dilihat Agent), pil model membuka daftar dari `GET .../models`.
  ///
  /// Melayang sungguhan: `ClipRRect` + `BackdropFilter` mengaburkan apa
  /// pun yang lewat di baliknya (daftar chat yang scroll penuh sampai ke
  /// bawah layar, lihat [_chatConversation]), dan warna latarnya
  /// tembus-pandang sebagian (`withValues(alpha: ...)`), bukan solid —
  /// itu yang membedakan "melayang" dari "kotak putih menempel di bawah".
  Widget _messageComposer(BuildContext context, ChatState state) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.1),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_hasPendingImages) _pendingStrip(scheme),
                TextField(
                  controller: _draftController,
                  enabled: !state.isSending,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _submit(context),
                  decoration: InputDecoration(
                    hintText: 'Tulis pesan untuk Wangsa',
                    hintStyle: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                    filled: false,
                    isCollapsed: true,
                    // WangsaTheme mendaftarkan focusedBorder bergaris warna
                    // primer secara global (lihat theme/wangsa_theme.dart) —
                    // tanpa menimpa ketiganya di sini, cincin fokus itu tetap
                    // muncul walau `border` sudah none, karena kartu composer
                    // ini sudah punya bingkainya sendiri.
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: TextStyle(color: scheme.onSurface, fontSize: 16),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    IconButton(
                      onPressed: state.isSending ? null : () => unawaited(_pickImage()),
                      tooltip: 'Lampiran',
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      color: scheme.onSurfaceVariant,
                    ),
                    _ModelPill(
                      label: state.effectiveModel ?? state.agent?.name ?? 'Wangsa',
                      onTap: () => _showModelPicker(context, state),
                    ),
                    const Spacer(),
                    IconButton.filled(
                      onPressed: () => unawaited(_toggleListening()),
                      tooltip: _isListening ? 'Berhenti mendengar' : 'Bicara',
                      icon: Icon(
                        _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.surface,
                        foregroundColor: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _draftController,
                      builder: (context, value, _) {
                        if (state.isSending) {
                          return IconButton.filled(
                            onPressed: () => context.read<ChatBloc>().add(const MessageCancelled()),
                            icon: const Icon(Icons.stop_rounded),
                            tooltip: 'Berhenti',
                          );
                        }
                        final hasText = value.text.trim().isNotEmpty;
                        final canSend = hasText || _hasPendingImages;
                        return IconButton.filled(
                          onPressed: canSend ? () => _submit(context) : null,
                          icon: const Icon(Icons.arrow_upward_rounded),
                          tooltip: 'Kirim',
                          // Ungu (gaya bawaan IconButton.filled) cuma waktu
                          // ada isi yang bisa dikirim — kosong berarti
                          // tombolnya memang tidak melakukan apa-apa kalau
                          // ditekan, jadi tidak boleh terlihat seolah aktif.
                          style: !canSend
                              ? IconButton.styleFrom(
                                  backgroundColor: scheme.surfaceContainerHighest,
                                  disabledBackgroundColor: scheme.surfaceContainerHighest,
                                  foregroundColor: scheme.onSurfaceVariant,
                                  disabledForegroundColor: scheme.onSurfaceVariant,
                                )
                              : null,
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Strip pratinjau gambar yang menunggu dikirim — tiap miniatur bisa
  /// dibuang lewat tombol silangnya sebelum pesan dikirim.
  Widget _pendingStrip(ColorScheme scheme) {
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
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    img.bytes,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 64,
                      height: 64,
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: scheme.onSurfaceVariant,
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
                        color: scheme.scrim.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
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

  /// Pil `+` dan pil model belum menyambung ke apa pun — bukan tombol
  /// palsu yang diam saat diketuk, tapi juga tidak berpura-pura berfungsi.
  // Skala tipografi laci — satu ukuran per peran, dipakai SEMUA baris
  // supaya konsisten: baris menu 15/w500 dengan ikon 22, judul bagian
  // 13/w700, keterangan 13, label "Segera" 12. Sebelumnya "Percakapan baru"
  // memakai ListTile bawaan (16, ikon 24) sedangkan sisanya masing-masing
  // punya ukuran sendiri.
  static const _drawerRowHeight = 48.0;
  static const _drawerHorizontalPadding = 16.0;

  /// Baris menu tunggal: dipakai "Percakapan baru" (aktif) dan semua
  /// placeholder (redup, `onTap` null = tidak aktif tapi tetap bisa memberi
  /// info lewat [onPlaceholderTap]).
  Widget _drawerRow(
    BuildContext context,
    IconData icon,
    String label, {
    VoidCallback? onTap,
    bool placeholder = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null || placeholder;
    final color = placeholder
        ? scheme.onSurfaceVariant.withValues(alpha: 0.65)
        : (enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38));
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap ?? (placeholder ? () => _notAvailableYet(context, label) : null),
      child: SizedBox(
        height: _drawerRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _drawerHorizontalPadding),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
              if (placeholder)
                Text('Segera', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drawerPlaceholder(BuildContext context, IconData icon, String label) =>
      _drawerRow(context, icon, label, placeholder: true);

  Widget _drawerSectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_drawerHorizontalPadding, 24, _drawerHorizontalPadding, 6),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _drawerEmptyNote(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _drawerHorizontalPadding, vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
          fontSize: 13,
        ),
      ),
    );
  }

  void _notAvailableYet(BuildContext context, String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what belum tersedia.')));
  }

  /// Lapisan suara: menimpa layar chat, bukan menggantikannya. Kedua
  /// jalur masuk (tombol mikrofon dan kata pemicu) berakhir di sini.
  /// Tidak ada kartu di sini dengan sengaja — orb, status, dan tombol
  /// Batal melayang langsung di atas backdrop gelap, meniru panggung
  /// gelap polos di referensi siri-orb smoothui.dev (lihat percakapan
  /// soal desain orb). Karena backdrop-nya SELALU gelap (scrim, bukan
  /// `scheme.surface`) terlepas dari mode terang/gelap aplikasi, warna
  /// teks di sini SENGAJA ditulis literal terang, bukan lewat token
  /// `scheme.onSurface`/dst yang justru gelap di tema terang — beda dari
  /// pola di tempat lain layar ini yang selalu ikut token tema.
  Widget _voiceOverlay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: GestureDetector(
        // Mengetuk area gelap membatalkan — perilaku standar lapisan
        // modal, dan satu-satunya cara keluar selain tombol Batal saat
        // pengguna berubah pikiran di tengah jalan.
        onTap: () => unawaited(_cancelVoiceOverlay()),
        child: Container(
          color: scheme.scrim.withValues(alpha: 0.82),
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            // Menelan ketukan supaya isinya sendiri tidak ikut menutup
            // lapisan saat disentuh.
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

/// Pil kecil di baris ikon composer, meniru penunjuk model di aplikasi
/// Claude. Menampilkan model efektif ([ChatState.effectiveModel]) bila
/// sudah dimuat dari server, kalau tidak nama Agent yang sedang aktif.
class _ModelPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ModelPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Nama Agent bisa panjang (mis. kalimat tujuan, bukan nama pendek),
    // jadi pil ini dibatasi lebarnya secara eksplisit — Text.overflow
    // saja tidak cukup di dalam Row yang tidak membatasi lebar anaknya.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 130),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
