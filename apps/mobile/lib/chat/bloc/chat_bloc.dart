import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../api/api_endpoints.dart';
import '../../api/models.dart';
import '../../api/wangsa_api_client.dart';
import '../../profile/user_profile_controller.dart';

part 'chat_event.dart';
part 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final WangsaApiClient apiClient;
  final String agentId;

  /// Sumber nama/preferensi yang dikirim bersama setiap pesan (lihat
  /// [_onMessageSubmitted]) supaya Agent menjawab sesuai profil pengguna.
  /// Dibaca langsung dari `.value` tiap giliran, bukan disalin ke state —
  /// controller ini sudah persisten sendiri (SharedPreferences) dan
  /// diedit dari layar Profil, bukan dari alur chat. Null (bawaan) berarti
  /// tidak ada profil untuk dikirim — pemanggil lama (dan test yang tidak
  /// menguji profil) tetap kompilasi tanpa perlu menyediakannya.
  final UserProfileController? userProfile;

  /// Penanda urutan pengiriman yang sedang aktif. Setiap kali pesan baru
  /// dikirim atau pengiriman dibatalkan, nomor ini naik. Balasan server
  /// yang tiba dengan nomor lama (mis. balasan yang datang setelah
  /// tombol batal ditekan) diabaikan begitu saja dan tidak menimpa status.
  int _activeSendId = 0;
  _RetryPayload? _retryPayload;

  /// Id sesi percakapan yang diterbitkan server pada balasan pertama.
  /// Null berarti percakapan baru belum dimulai; diteruskan kembali
  /// pada pesan berikutnya agar riwayat percakapan berlanjut di server.
  String? _sessionId;

  /// Kandidat alamat API untuk fallback otomatis bila URL utama gagal total
  /// (RUNTIME_ERROR). Dibangun sekali oleh AuthGate dari URL simpanan +
  /// bawaan localhost/emulator (lihat `buildApiCandidates`). Kosong berarti
  /// perilaku lama: gagal sekali langsung tampil galat.
  final List<String> candidateUrls;

  /// Batas tunggu tiap kandidat saat probing fallback. Sengaja pendek (3
  /// detik): ini cek "server hidup?", bukan menunggu balasan Agent.
  final Duration probeTimeout;

  /// Pabrik klien sementara untuk probing. Produksi null (klien HTTP asli);
  /// test menyuntikkan MockClient lewat sini tanpa menyentuh jaringan.
  final WangsaApiClient Function(String url)? clientFactory;

  /// Dipanggil tepat sekali tiap probing menemukan URL hidup yang berbeda
  /// dari URL utama, supaya pemilik sesi (AuthGate) menyimpan URL baru ke
  /// SharedPreferences dan menyelaraskan kunci sesinya. Tanpa ini, hasil
  /// self-healing hilang saat aplikasi dibuka ulang berikutnya.
  final void Function(String url)? onApiBaseUrlResolved;

  /// Penelusuran backend LAN sebagai upaya terakhir setelah kandidat
  /// statis mati (lihat `discoverLanBackendUrls` di api_endpoints.dart).
  /// Null (bawaan) = nonaktif: unit test dan lingkungan tanpa jaringan
  /// tidak akan pernah menyentuh `NetworkInterface`/socket sungguhan.
  /// AuthGate menyuntikkan penelusuran sungguhan di produksi.
  final Future<List<String>> Function()? lanDiscoverer;

  ChatBloc({
    required this.apiClient,
    required this.agentId,
    this.userProfile,
    this.candidateUrls = const [],
    this.probeTimeout = const Duration(seconds: 3),
    this.clientFactory,
    this.onApiBaseUrlResolved,
    this.lanDiscoverer,
  }) : super(const ChatState()) {
    on<ChatOpened>(_onOpened);
    on<MessageSubmitted>(_onMessageSubmitted);
    on<MessageRetried>(_onMessageRetried);
    on<ModelSelected>(_onModelSelected);
    on<ToolsetsSelected>(_onToolsetsSelected);
    on<ConversationCleared>(_onConversationCleared);
    on<AgentBuildRequested>(_onAgentBuildRequested);
    on<MessageCancelled>(_onMessageCancelled);
    on<SessionsRequested>(_onSessionsRequested);
    on<SessionSelected>(_onSessionSelected);
    on<SessionDeleted>(_onSessionDeleted);
    on<ApiBaseUrlChanged>(_onApiBaseUrlChanged);
    on<ModelsRequested>(_onModelsRequested);
    on<SetupStatusRequested>(_onSetupStatusRequested);
  }

  Future<void> _onApiBaseUrlChanged(
    ApiBaseUrlChanged event,
    Emitter<ChatState> emit,
  ) async {
    apiClient.updateBaseUrl(event.newUrl);
    _sessionId = null;
    emit(
      state.copyWith(
        status: ChatStatus.loading,
        turns: const [],
        clearCurrentActivity: true,
        clearToolActivities: true,
        clearStreamingText: true,
        clearSessionId: true,
        selectedToolsets: const [],
        clearError: true,
        canRetry: false,
      ),
    );
    add(const ChatOpened());
  }

  void _onToolsetsSelected(ToolsetsSelected event, Emitter<ChatState> emit) {
    if (state.isSending || state.turns.isNotEmpty || state.sessionId != null) {
      return;
    }
    const allowed = {'web', 'vision'};
    final selected = event.toolsets.toSet();
    if (!allowed.containsAll(selected)) return;
    emit(state.copyWith(selectedToolsets: selected.toList()..sort()));
  }

  bool _hasSelectedModel(
    List<String> activeModels,
    List<ProviderOption> availableProviders,
  ) {
    final model = state.selectedModel;
    if (model == null) return false;
    final provider = state.selectedProvider;
    if (provider != null) {
      return availableProviders.any(
        (entry) => entry.id == provider && entry.models.contains(model),
      );
    }
    return activeModels.contains(model) ||
        availableProviders.any((entry) => entry.models.contains(model));
  }

  bool _hasAvailableCurrentModel(
    String currentModel,
    String currentProvider,
    List<String> activeModels,
    List<ProviderOption> availableProviders,
  ) {
    if (currentModel.isEmpty) return false;
    if (activeModels.contains(currentModel)) return true;
    return availableProviders.any(
      (entry) =>
          entry.id == currentProvider && entry.models.contains(currentModel),
    );
  }

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    emit(state.copyWith(status: ChatStatus.loading, clearError: true));

    var result = await apiClient.getAgent(agentId);
    if (!result.isSuccess && result.errorOrNull?.code == 'RUNTIME_ERROR') {
      // URL utama gagal total (bukan ditolak server — servernya memang tak
      // terjangkau). Sebelum menyerah, coba kandidat lain: URL simpanan
      // bisa basi (DHCP), adb reverse bisa hilang, backend bisa pindah.
      String? found;
      if (candidateUrls.isNotEmpty) {
        found = await findReachableApiUrl(
          candidates: candidateUrls,
          agentId: agentId,
          currentUrl: apiClient.baseUrl,
          timeout: probeTimeout,
          clientFactory: clientFactory,
        );
      }
      // Kandidat statis juga mati: telusuri subnet Wi-Fi lokal HP untuk
      // backend yang tidak tersimpan siapa pun (HP baru satu jaringan
      // dengan laptop). Galat penelusuran tidak menggagalkan pesan —
      // layar tetap menampilkan petunjuk host seperti biasa.
      if (found == null && lanDiscoverer != null) {
        try {
          final lanUrls = await lanDiscoverer!();
          if (lanUrls.isNotEmpty) {
            found = await findReachableApiUrl(
              candidates: lanUrls,
              agentId: agentId,
              currentUrl: apiClient.baseUrl,
              timeout: probeTimeout,
              clientFactory: clientFactory,
            );
          }
        } catch (_) {
          // Penelusuran gagal (jaringan filmis, platform tanpa socket) —
          // lanjut ke layar galat biasa.
        }
      }
      if (found != null && found != apiClient.baseUrl) {
        apiClient.updateBaseUrl(found);
        onApiBaseUrlResolved?.call(found);
        result = await apiClient.getAgent(agentId);
      }
    }
    if (!result.isSuccess) {
      final notFound = result.errorOrNull?.code == 'NOT_FOUND';
      final base =
          result.errorOrNull?.message ?? 'Tidak bisa menghubungi API Wangsa.';
      emit(
        state.copyWith(
          status: notFound ? ChatStatus.notFound : ChatStatus.failed,
          // RUNTIME_ERROR selalu ditempeli petunjuk spesifik-host supaya
          // layar "Gagal terhubung" menjawab "saya harus apa?" — bukan
          // sekadar "gagal". NOT_FOUND punya layar sendiri, tak perlu hint.
          errorMessage: notFound || result.errorOrNull?.code != 'RUNTIME_ERROR'
              ? (notFound ? null : base)
              : '$base\n\n${diagnoseConnectionHint(apiClient.baseUrl)}',
        ),
      );
      return;
    }

    emit(state.copyWith(status: ChatStatus.ready, agent: result.dataOrNull));

    final models = await apiClient.getModels(agentId);
    if (models.isSuccess && models.dataOrNull != null) {
      final options = models.dataOrNull!;
      final clearStaleSelection =
          state.selectedModel != null &&
          !_hasSelectedModel(options.models, options.providers);
      final currentModelAvailable = _hasAvailableCurrentModel(
        options.current,
        options.provider,
        options.models,
        options.providers,
      );
      emit(
        state.copyWith(
          models: options.models,
          providers: options.providers,
          currentProvider: options.provider.isEmpty ? null : options.provider,
          currentModel: currentModelAvailable ? options.current : null,
          clearCurrentModel: !currentModelAvailable,
          clearSelectedModel: clearStaleSelection,
          clearSelectedProvider: clearStaleSelection,
        ),
      );
    }

    add(const SetupStatusRequested());
  }

  Future<void> _onSetupStatusRequested(
    SetupStatusRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(isCheckingSetup: true));
    final me = await apiClient.getMe();
    if (me.isSuccess && me.dataOrNull != null) {
      final info = me.dataOrNull!;
      // Budget diambil dulu agar satu emisi membawa setup + budget sekaligus
      // (satu rebuild, bukan dua).
      final budget = await apiClient.getBudget();
      emit(
        state.copyWith(
          profileName: info.profile,
          needsSetup: !info.configured,
          isCheckingSetup: false,
          budget: budget.dataOrNull,
          authInvalid: false,
        ),
      );
      return;
    }
    // Server terbuka tanpa token (localhost-only lama): fallback ke daftar
    // provider — butuh minimal 1 non-gratis yang configured.
    final code = me.errorOrNull?.code;
    if (code == 'UNAUTHORIZED' || code == 'PROFILE_UNAVAILABLE') {
      emit(
        state.copyWith(
          isCheckingSetup: false,
          authInvalid: true,
          errorMessage: me.errorOrNull?.message,
        ),
      );
      return;
    }
    final providers = await apiClient.getAuthProviders();
    if (providers.isSuccess && providers.dataOrNull != null) {
      final hasKey = providers.dataOrNull!.any(
        (p) => p.configured && p.id != 'opencode-free',
      );
      emit(state.copyWith(needsSetup: !hasKey, isCheckingSetup: false));
      return;
    }
    emit(state.copyWith(isCheckingSetup: false));
  }

  void _onModelSelected(ModelSelected event, Emitter<ChatState> emit) {
    final model = event.model?.trim();
    final provider = event.provider?.trim();
    if (model == null || model.isEmpty) {
      emit(
        state.copyWith(clearSelectedModel: true, clearSelectedProvider: true),
      );
    } else {
      emit(
        state.copyWith(
          selectedModel: model,
          selectedProvider: provider != null && provider.isNotEmpty
              ? provider
              : null,
        ),
      );
    }
  }

  Future<void> _onMessageSubmitted(
    MessageSubmitted event,
    Emitter<ChatState> emit,
  ) => _sendMessage(event.message, event.images, emit);

  Future<void> _onMessageRetried(
    MessageRetried event,
    Emitter<ChatState> emit,
  ) async {
    final retry = _retryPayload;
    if (retry == null || state.isSending) return;
    await _sendMessage(retry.message, retry.images, emit, retry: true);
  }

  Future<void> _sendMessage(
    String rawMessage,
    List<ChatImage> images,
    Emitter<ChatState> emit, {
    bool retry = false,
  }) async {
    final message = rawMessage.trim();
    if ((message.isEmpty && images.isEmpty) || state.isSending) return;
    if (state.needsSetup) {
      emit(
        state.copyWith(
          errorMessage:
              'Hubungkan LLM dulu lewat Setup Provider, lalu coba lagi.',
        ),
      );
      return;
    }

    final sendId = ++_activeSendId;
    final baseTurns = retry
        ? (_retryPayload?.baseTurns ?? state.turns)
        : state.turns;
    final withUserTurn = [
      ...baseTurns,
      Turn(role: TurnRole.user, content: message, imageCount: images.length),
    ];
    _retryPayload = _RetryPayload(message, images, baseTurns);
    emit(
      state.copyWith(
        turns: withUserTurn,
        isSending: true,
        clearCurrentActivity: true,
        clearToolActivities: true,
        clearStreamingText: true,
        clearError: true,
        canRetry: false,
      ),
    );

    final profile = userProfile?.value;
    final result = await apiClient.sendMessage(
      agentId,
      message,
      model: state.effectiveModel,
      provider: state.effectiveProvider,
      toolsets: state.selectedToolsets,
      images: images,
      sessionId: _sessionId,
      userName: profile != null && profile.name.trim().isNotEmpty
          ? profile.name
          : null,
      userBio: profile != null && profile.preferences.trim().isNotEmpty
          ? profile.preferences
          : null,
      onActivity: (activity) {
        if (sendId == _activeSendId && !emit.isDone) {
          final activities = [...state.toolActivities];
          final match = activity.index == null
              ? -1
              : activities.lastIndexWhere(
                  (item) =>
                      item.index == activity.index &&
                      item.tool == activity.tool &&
                      item.status == 'running',
                );
          if (match >= 0) {
            final previous = activities[match];
            activities[match] = ToolCallInfo(
              tool: activity.tool,
              preview: activity.preview.isEmpty
                  ? previous.preview
                  : activity.preview,
              status: activity.status,
              index: activity.index,
            );
          } else {
            activities.add(activity);
          }
          emit(
            state.copyWith(
              currentActivity: activity,
              toolActivities: activities,
            ),
          );
        }
      },
      onDelta: (delta) {
        if (sendId == _activeSendId && !emit.isDone) {
          emit(state.copyWith(streamingText: '${state.streamingText}$delta'));
        }
      },
    );
    if (sendId != _activeSendId) return;
    final reply = result.dataOrNull;

    if (result.isSuccess && reply != null) {
      if (reply.sessionId.isNotEmpty) {
        _sessionId = reply.sessionId;
      }
      emit(
        state.copyWith(
          sessionId: _sessionId,
          turns: [
            ...withUserTurn,
            Turn(
              role: TurnRole.agent,
              content: reply.response,
              images: reply.images,
              files: reply.files,
              thought: reply.thought,
              toolCalls: reply.toolCalls.isNotEmpty
                  ? reply.toolCalls
                  : state.toolActivities,
              sources: reply.sources,
            ),
          ],
          isSending: false,
          clearCurrentActivity: true,
          clearToolActivities: true,
          clearStreamingText: true,
          canRetry: false,
        ),
      );
      _retryPayload = null;
      return;
    }

    final code = result.errorOrNull?.code;
    // Budget habis di tengah jalan: user turn sudah tampil, tampilkan pesan
    // server + segarkan angka budget agar banner akurat.
    if (code == 'BUDGET_EXCEEDED') {
      emit(
        state.copyWith(
          isSending: false,
          clearCurrentActivity: true,
          clearToolActivities: true,
          clearStreamingText: true,
          canRetry: false,
          errorMessage: result.errorOrNull?.message ?? 'Budget tercapai.',
        ),
      );
      _retryPayload = null;
      add(const SetupStatusRequested());
      return;
    }

    emit(
      state.copyWith(
        turns: state.streamingText.isEmpty
            ? null
            : [
                ...state.turns,
                Turn(
                  role: TurnRole.agent,
                  content: state.streamingText,
                  toolCalls: state.toolActivities,
                ),
              ],
        isSending: false,
        clearCurrentActivity: true,
        clearToolActivities: true,
        clearStreamingText: true,
        canRetry: _retryPayload != null,
        errorMessage: result.errorOrNull?.message ?? 'Pesan gagal terkirim.',
      ),
    );
  }

  void _onConversationCleared(
    ConversationCleared event,
    Emitter<ChatState> emit,
  ) {
    if (state.isSending) return;
    _sessionId = null;
    _retryPayload = null;
    emit(
      state.copyWith(
        turns: const [],
        clearCurrentActivity: true,
        clearToolActivities: true,
        clearStreamingText: true,
        clearSessionId: true,
        selectedToolsets: const [],
        clearError: true,
        canRetry: false,
      ),
    );
  }

  Future<void> _onAgentBuildRequested(
    AgentBuildRequested event,
    Emitter<ChatState> emit,
  ) async {
    if (state.isSending) return;
    _onConversationCleared(const ConversationCleared(), emit);
    await _onMessageSubmitted(MessageSubmitted(event.brief), emit);
  }

  void _onMessageCancelled(MessageCancelled event, Emitter<ChatState> emit) {
    if (!state.isSending) return;
    _activeSendId++;
    apiClient.cancelInFlight();
    emit(
      state.copyWith(
        turns: state.streamingText.isEmpty
            ? null
            : [
                ...state.turns,
                Turn(
                  role: TurnRole.agent,
                  content: state.streamingText,
                  toolCalls: state.toolActivities,
                ),
              ],
        isSending: false,
        clearCurrentActivity: true,
        clearToolActivities: true,
        clearStreamingText: true,
        canRetry: _retryPayload != null,
        errorMessage:
            'Jawaban dihentikan. Kamu bisa melanjutkan dengan mencoba lagi.',
      ),
    );
  }

  Future<void> _onSessionsRequested(
    SessionsRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(isLoadingSessions: true));
    final res = await apiClient.getSessions(agentId);
    if (res.isSuccess && res.dataOrNull != null) {
      emit(state.copyWith(sessions: res.dataOrNull!, isLoadingSessions: false));
    } else {
      emit(state.copyWith(isLoadingSessions: false));
    }
  }

  Future<void> _onSessionSelected(
    SessionSelected event,
    Emitter<ChatState> emit,
  ) async {
    if (state.isSending) return;
    _sessionId = event.sessionId;
    _retryPayload = null;
    final selectedSession = state.sessions.where(
      (session) => session.sessionId == event.sessionId,
    );
    final sessionToolsets = selectedSession.isEmpty
        ? const <String>[]
        : selectedSession.first.toolsets;
    emit(
      state.copyWith(
        sessionId: _sessionId,
        turns: const [],
        clearCurrentActivity: true,
        clearToolActivities: true,
        clearStreamingText: true,
        selectedToolsets: sessionToolsets,
        isLoadingHistory: true,
        clearError: true,
        canRetry: false,
      ),
    );

    final res = await apiClient.getSessionMessages(agentId, event.sessionId);
    // Sesi bisa berganti lagi (atau berpindah ke "percakapan baru") selagi
    // permintaan riwayat ini masih di jalan — jangan timpa layar dengan
    // transkrip sesi yang sudah tidak dipilih lagi.
    if (_sessionId != event.sessionId) return;

    if (res.isSuccess) {
      final turns = [
        for (final t in res.dataOrNull ?? const <HistoryTurn>[])
          Turn(
            role: t.isUser ? TurnRole.user : TurnRole.agent,
            content: t.content,
          ),
      ];
      emit(state.copyWith(turns: turns, isLoadingHistory: false));
    } else {
      emit(
        state.copyWith(
          isLoadingHistory: false,
          errorMessage:
              res.errorOrNull?.message ?? 'Gagal memuat riwayat sesi.',
        ),
      );
    }
  }

  Future<void> _onSessionDeleted(
    SessionDeleted event,
    Emitter<ChatState> emit,
  ) async {
    final res = await apiClient.deleteSession(agentId, event.sessionId);
    if (res.isSuccess) {
      final updated = state.sessions
          .where((s) => s.sessionId != event.sessionId)
          .toList();
      final bool clearingCurrent = state.sessionId == event.sessionId;
      if (clearingCurrent) {
        _sessionId = null;
        _retryPayload = null;
      }
      emit(
        state.copyWith(
          sessions: updated,
          sessionId: clearingCurrent ? null : state.sessionId,
          clearSessionId: clearingCurrent,
          turns: clearingCurrent ? const [] : state.turns,
          canRetry: clearingCurrent ? false : state.canRetry,
          selectedToolsets: clearingCurrent ? const [] : state.selectedToolsets,
        ),
      );
    }
  }

  Future<void> _onModelsRequested(
    ModelsRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(isLoadingModels: true, clearModelsError: true));
    final models = await apiClient.getModels(agentId);
    if (models.isSuccess && models.dataOrNull != null) {
      final options = models.dataOrNull!;
      final clearStaleSelection =
          state.selectedModel != null &&
          !_hasSelectedModel(options.models, options.providers);
      final currentModelAvailable = _hasAvailableCurrentModel(
        options.current,
        options.provider,
        options.models,
        options.providers,
      );
      emit(
        state.copyWith(
          models: options.models,
          providers: options.providers,
          currentProvider: options.provider,
          currentModel: currentModelAvailable ? options.current : null,
          clearCurrentModel: !currentModelAvailable,
          isLoadingModels: false,
          clearModelsError: true,
          clearSelectedModel: clearStaleSelection,
          clearSelectedProvider: clearStaleSelection,
        ),
      );
      return;
    }
    emit(
      state.copyWith(
        isLoadingModels: false,
        modelsError:
            models.errorOrNull?.message ?? 'Daftar model gagal dimuat.',
      ),
    );
  }
}

class _RetryPayload {
  final String message;
  final List<ChatImage> images;
  final List<Turn> baseTurns;

  const _RetryPayload(this.message, this.images, this.baseTurns);
}
