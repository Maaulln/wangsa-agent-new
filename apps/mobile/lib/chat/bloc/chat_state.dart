part of 'chat_bloc.dart';

enum ChatStatus { initial, loading, ready, notFound, failed }

enum TurnRole { user, agent }

class Turn extends Equatable {
  final TurnRole role;
  final String content;

  /// Jumlah gambar yang dikirim bersama giliran pengguna ini (0 bila
  /// tidak ada). Dipakai gelembung pesan untuk menandai lampiran.
  final int imageCount;

  /// Gambar yang dikirim Agent bersama giliran ini (kosong pada giliran
  /// pengguna — lampiran pengguna hanya dihitung lewat [imageCount],
  /// isinya tidak disimpan balik di state). Lihat [ReplyImage].
  final List<ReplyImage> images;

  /// Dokumen/audio yang dikirim Agent bersama giliran ini. Lihat [ReplyFile].
  final List<ReplyFile> files;

  const Turn({
    required this.role,
    required this.content,
    this.imageCount = 0,
    this.images = const [],
    this.files = const [],
  });

  @override
  List<Object?> get props => [role, content, imageCount, images, files];
}

class ChatState extends Equatable {
  final ChatStatus status;
  final PublicAgent? agent;
  final List<Turn> turns;
  final bool isSending;

  /// Galat satu kali yang layak ditunjukkan, misalnya pesan gagal
  /// terkirim. Selalu dikosongkan pada giliran berikutnya supaya tidak
  /// menempel di layar.
  final String? errorMessage;

  /// Id model yang bisa dipilih di provider aktif, dari
  /// `GET .../models`. Kosong berarti daftar belum dimuat (atau gagal
  /// dimuat — bukan fatal, kirim tetap jalan dengan bawaan server).
  final List<String> models;

  /// Model yang sedang aktif di server untuk sesi ini.
  final String? currentModel;

  /// Pilihan pengguna lewat pil model. Null berarti ikut [currentModel]
  /// (bawaan deployment).
  final String? selectedModel;

  const ChatState({
    this.status = ChatStatus.initial,
    this.agent,
    this.turns = const [],
    this.isSending = false,
    this.errorMessage,
    this.models = const [],
    this.currentModel,
    this.selectedModel,
  });

  /// Model yang benar-benar dikirim ke server: pilihan pengguna bila
  /// ada, kalau tidak model aktif server.
  String? get effectiveModel => selectedModel ?? currentModel;

  ChatState copyWith({
    ChatStatus? status,
    PublicAgent? agent,
    List<Turn>? turns,
    bool? isSending,
    String? errorMessage,
    bool clearError = false,
    List<String>? models,
    String? currentModel,
    String? selectedModel,
    bool clearSelectedModel = false,
  }) =>
      ChatState(
        status: status ?? this.status,
        agent: agent ?? this.agent,
        turns: turns ?? this.turns,
        isSending: isSending ?? this.isSending,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        models: models ?? this.models,
        currentModel: currentModel ?? this.currentModel,
        selectedModel: clearSelectedModel ? null : (selectedModel ?? this.selectedModel),
      );

  @override
  List<Object?> get props => [status, agent?.id, turns, isSending, errorMessage, models, currentModel, selectedModel];
}
