import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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

  /// Id sesi percakapan yang diterbitkan server pada balasan pertama.
  /// Null berarti percakapan baru belum dimulai; diteruskan kembali
  /// pada pesan berikutnya agar riwayat percakapan berlanjut di server.
  String? _sessionId;

  ChatBloc({
    required this.apiClient,
    required this.agentId,
    this.userProfile,
  }) : super(const ChatState()) {
    on<ChatOpened>(_onOpened);
    on<MessageSubmitted>(_onMessageSubmitted);
    on<ModelSelected>(_onModelSelected);
    on<ConversationCleared>(_onConversationCleared);
    on<MessageCancelled>(_onMessageCancelled);
    on<SessionsRequested>(_onSessionsRequested);
    on<SessionSelected>(_onSessionSelected);
    on<SessionDeleted>(_onSessionDeleted);
    on<ApiBaseUrlChanged>(_onApiBaseUrlChanged);
    on<ModelsRequested>(_onModelsRequested);
  }

  Future<void> _onApiBaseUrlChanged(ApiBaseUrlChanged event, Emitter<ChatState> emit) async {
    apiClient.updateBaseUrl(event.newUrl);
    _sessionId = null;
    emit(state.copyWith(status: ChatStatus.loading, turns: const [], clearError: true));
    add(const ChatOpened());
  }

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    emit(state.copyWith(status: ChatStatus.loading, clearError: true));

    final result = await apiClient.getAgent(agentId);
    if (!result.isSuccess) {
      final notFound = result.errorOrNull?.code == 'NOT_FOUND';
      emit(
        state.copyWith(
          status: notFound ? ChatStatus.notFound : ChatStatus.failed,
          errorMessage: notFound ? null : result.errorOrNull?.message,
        ),
      );
      return;
    }

    emit(state.copyWith(status: ChatStatus.ready, agent: result.dataOrNull));

    final models = await apiClient.getModels(agentId);
    if (models.isSuccess && models.dataOrNull != null) {
      final options = models.dataOrNull!;
      emit(
        state.copyWith(
          models: options.models,
          providers: options.providers,
          currentProvider: options.provider.isEmpty ? null : options.provider,
          currentModel: options.current.isEmpty ? null : options.current,
        ),
      );
    }
  }

  void _onModelSelected(ModelSelected event, Emitter<ChatState> emit) {
    final model = event.model?.trim();
    final provider = event.provider?.trim();
    if (model == null || model.isEmpty) {
      emit(state.copyWith(clearSelectedModel: true, clearSelectedProvider: true));
    } else {
      emit(state.copyWith(
        selectedModel: model,
        selectedProvider: provider != null && provider.isNotEmpty ? provider : null,
      ));
    }
  }

  Future<void> _onMessageSubmitted(MessageSubmitted event, Emitter<ChatState> emit) async {
    final message = event.message.trim();
    if ((message.isEmpty && event.images.isEmpty) || state.isSending) return;

    final sendId = ++_activeSendId;
    final withUserTurn = [
      ...state.turns,
      Turn(role: TurnRole.user, content: message, imageCount: event.images.length),
    ];
    emit(state.copyWith(turns: withUserTurn, isSending: true, clearError: true));

    final profile = userProfile?.value;
    final result = await apiClient.sendMessage(
      agentId,
      message,
      model: state.effectiveModel,
      provider: state.effectiveProvider,
      images: event.images,
      sessionId: _sessionId,
      userName: profile != null && profile.name.trim().isNotEmpty ? profile.name : null,
      userBio: profile != null && profile.preferences.trim().isNotEmpty ? profile.preferences : null,
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
              toolCalls: reply.toolCalls,
            ),
          ],
          isSending: false,
        ),
      );
      return;
    }

    emit(
      state.copyWith(
        isSending: false,
        errorMessage: result.errorOrNull?.message ?? 'Pesan gagal terkirim.',
      ),
    );
  }

  void _onConversationCleared(ConversationCleared event, Emitter<ChatState> emit) {
    if (state.isSending) return;
    _sessionId = null;
    emit(state.copyWith(turns: const [], clearSessionId: true, clearError: true));
  }

  void _onMessageCancelled(MessageCancelled event, Emitter<ChatState> emit) {
    if (!state.isSending) return;
    _activeSendId++;
    apiClient.cancelInFlight();
    emit(state.copyWith(isSending: false));
  }

  Future<void> _onSessionsRequested(SessionsRequested event, Emitter<ChatState> emit) async {
    emit(state.copyWith(isLoadingSessions: true));
    final res = await apiClient.getSessions(agentId);
    if (res.isSuccess && res.dataOrNull != null) {
      emit(state.copyWith(sessions: res.dataOrNull!, isLoadingSessions: false));
    } else {
      emit(state.copyWith(isLoadingSessions: false));
    }
  }

  Future<void> _onSessionSelected(SessionSelected event, Emitter<ChatState> emit) async {
    if (state.isSending) return;
    _sessionId = event.sessionId;
    emit(state.copyWith(sessionId: _sessionId, turns: const [], isLoadingHistory: true, clearError: true));

    final res = await apiClient.getSessionMessages(agentId, event.sessionId);
    // Sesi bisa berganti lagi (atau berpindah ke "percakapan baru") selagi
    // permintaan riwayat ini masih di jalan — jangan timpa layar dengan
    // transkrip sesi yang sudah tidak dipilih lagi.
    if (_sessionId != event.sessionId) return;

    if (res.isSuccess) {
      final turns = [
        for (final t in res.dataOrNull ?? const <HistoryTurn>[])
          Turn(role: t.isUser ? TurnRole.user : TurnRole.agent, content: t.content),
      ];
      emit(state.copyWith(turns: turns, isLoadingHistory: false));
    } else {
      emit(
        state.copyWith(
          isLoadingHistory: false,
          errorMessage: res.errorOrNull?.message ?? 'Gagal memuat riwayat sesi.',
        ),
      );
    }
  }

  Future<void> _onSessionDeleted(SessionDeleted event, Emitter<ChatState> emit) async {
    final res = await apiClient.deleteSession(agentId, event.sessionId);
    if (res.isSuccess) {
      final updated = state.sessions.where((s) => s.sessionId != event.sessionId).toList();
      final bool clearingCurrent = state.sessionId == event.sessionId;
      if (clearingCurrent) {
        _sessionId = null;
      }
      emit(
        state.copyWith(
          sessions: updated,
          sessionId: clearingCurrent ? null : state.sessionId,
          clearSessionId: clearingCurrent,
          turns: clearingCurrent ? const [] : state.turns,
        ),
      );
    }
  }

  Future<void> _onModelsRequested(ModelsRequested event, Emitter<ChatState> emit) async {
    final models = await apiClient.getModels(agentId);
    if (models.isSuccess && models.dataOrNull != null) {
      final options = models.dataOrNull!;
      emit(
        state.copyWith(
          models: options.models,
          providers: options.providers,
          currentProvider: options.provider,
        ),
      );
    }
  }
}
