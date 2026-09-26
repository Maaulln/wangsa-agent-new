part of 'chat_bloc.dart';

enum ChatStatus { initial, loading, ready, notFound, failed }

enum TurnRole { user, agent }

class Turn extends Equatable {
  final TurnRole role;
  final String content;
  final int imageCount;
  final List<ReplyImage> images;
  final List<ReplyFile> files;
  final String thought;
  final List<ToolCallInfo> toolCalls;

  const Turn({
    required this.role,
    required this.content,
    this.imageCount = 0,
    this.images = const [],
    this.files = const [],
    this.thought = '',
    this.toolCalls = const [],
  });

  @override
  List<Object?> get props => [
    role,
    content,
    imageCount,
    images,
    files,
    thought,
    toolCalls,
  ];
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
  final bool isLoadingModels;
  final String? modelsError;

  /// Seluruh provider dan daftar modelnya yang tersedia di server.
  final List<ProviderOption> providers;

  /// Provider yang sedang aktif di server (bawaan deployment).
  final String? currentProvider;

  /// Provider pilihan pengguna. Null berarti ikut [currentProvider].
  final String? selectedProvider;

  /// Model yang sedang aktif di server untuk sesi ini.
  final String? currentModel;

  /// Pilihan pengguna lewat pil model. Null berarti ikut [currentModel]
  /// (bawaan deployment).
  final String? selectedModel;

  /// Sesi aktif saat ini.
  final String? sessionId;

  /// Kapabilitas untuk chat baru; kosong berarti percakapan biasa tanpa tool.
  final List<String> selectedToolsets;

  /// Riwayat sesi percakapan untuk drawer.
  final List<SessionSummary> sessions;

  final bool isLoadingSessions;

  /// Sedang memuat transkrip sesi yang baru dipilih dari drawer.
  final bool isLoadingHistory;

  /// Profile milik token ini (dari `GET /api/v1/auth/me`).
  final String? profileName;

  /// True bila profile belum menghubungkan LLM non-gratis. Chat diblokir
  /// sampai user menyelesaikan Setup Provider.
  final bool needsSetup;

  /// Sedang memuat status setup (me + providers).
  final bool isCheckingSetup;

  /// Ringkasan budget spend profile (null = belum dimuat / tanpa cap).
  final BudgetInfo? budget;

  /// True bila token ditolak server (401/503 saat cek status). Chat
  /// menampilkan banner keluar — user harus daftar/masuk ulang.
  final bool authInvalid;

  const ChatState({
    this.status = ChatStatus.initial,
    this.agent,
    this.turns = const [],
    this.isSending = false,
    this.errorMessage,
    this.models = const [],
    this.isLoadingModels = false,
    this.modelsError,
    this.providers = const [],
    this.currentProvider,
    this.selectedProvider,
    this.currentModel,
    this.selectedModel,
    this.sessionId,
    this.selectedToolsets = const [],
    this.sessions = const [],
    this.isLoadingSessions = false,
    this.isLoadingHistory = false,
    this.profileName,
    this.needsSetup = false,
    this.isCheckingSetup = false,
    this.budget,
    this.authInvalid = false,
  });

  /// Provider yang dikirim ke server: pilihan pengguna bila ada,
  /// kalau tidak provider aktif server.
  String? get effectiveProvider => selectedProvider ?? currentProvider;

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
    bool? isLoadingModels,
    String? modelsError,
    bool clearModelsError = false,
    List<ProviderOption>? providers,
    String? currentProvider,
    String? selectedProvider,
    bool clearSelectedProvider = false,
    String? currentModel,
    bool clearCurrentModel = false,
    String? selectedModel,
    bool clearSelectedModel = false,
    String? sessionId,
    bool clearSessionId = false,
    List<String>? selectedToolsets,
    List<SessionSummary>? sessions,
    bool? isLoadingSessions,
    bool? isLoadingHistory,
    String? profileName,
    bool? needsSetup,
    bool? isCheckingSetup,
    BudgetInfo? budget,
    bool? authInvalid,
  }) => ChatState(
    status: status ?? this.status,
    agent: agent ?? this.agent,
    turns: turns ?? this.turns,
    isSending: isSending ?? this.isSending,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    models: models ?? this.models,
    isLoadingModels: isLoadingModels ?? this.isLoadingModels,
    modelsError: clearModelsError ? null : (modelsError ?? this.modelsError),
    providers: providers ?? this.providers,
    currentProvider: currentProvider ?? this.currentProvider,
    selectedProvider: clearSelectedProvider
        ? null
        : (selectedProvider ?? this.selectedProvider),
    currentModel: clearCurrentModel
        ? null
        : (currentModel ?? this.currentModel),
    selectedModel: clearSelectedModel
        ? null
        : (selectedModel ?? this.selectedModel),
    sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
    selectedToolsets: selectedToolsets ?? this.selectedToolsets,
    sessions: sessions ?? this.sessions,
    isLoadingSessions: isLoadingSessions ?? this.isLoadingSessions,
    isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
    profileName: profileName ?? this.profileName,
    needsSetup: needsSetup ?? this.needsSetup,
    isCheckingSetup: isCheckingSetup ?? this.isCheckingSetup,
    budget: budget ?? this.budget,
    authInvalid: authInvalid ?? this.authInvalid,
  );

  @override
  List<Object?> get props => [
    status,
    agent?.id,
    turns,
    isSending,
    errorMessage,
    models,
    isLoadingModels,
    modelsError,
    providers,
    currentProvider,
    selectedProvider,
    currentModel,
    selectedModel,
    sessionId,
    selectedToolsets,
    sessions,
    isLoadingSessions,
    isLoadingHistory,
    profileName,
    needsSetup,
    isCheckingSetup,
    budget,
    authInvalid,
  ];
}
