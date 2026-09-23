import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../api/models.dart';
import '../../api/wangsa_api_client.dart';

part 'chat_event.dart';
part 'chat_state.dart';

/// Mengelola status layar percakapan: memuat data Agent, mengirim pesan,
/// dan mengumpulkan riwayat giliran (Turn).
///
/// BLoC ini HANYA tahu teks dan gambar — ia tidak tahu kata pemicu,
/// mikrofon, maupun rekaman suara. Lapisan suara di luar (lapisan presenter
/// di chat_page.dart) yang menerjemahkan suara menjadi teks sebelum
/// diserahkan ke sini lewat [MessageSubmitted].
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final WangsaApiClient apiClient;
  final String agentId;

  /// Penanda pengiriman yang sedang aktif. Setiap pengiriman baru
  /// menaikkan nilainya; jika pesan dibatalkan di tengah jalan, nilainya
  /// dinaikkan lagi supaya balasan yang datang terlambat (mis. dari
  /// koneksi yang baru putus) diabaikan dan tidak menimpa state.
  int _activeSendId = 0;

  /// ID sesi yang diterbitkan server pada balasan pertama. Dikirim balik
  /// pada pesan berikutnya agar riwayat percakapan berlanjut di server.
  String? _sessionId;

  ChatBloc({required this.apiClient, required this.agentId})
      : super(const ChatState()) {
    on<ChatOpened>(_onOpened);
    on<MessageSubmitted>(_onMessageSubmitted);
    on<ModelSelected>(_onModelSelected);
    on<ConversationCleared>(_onConversationCleared);
    on<MessageCancelled>(_onMessageCancelled);
    on<SessionsRequested>(_onSessionsRequested);
    on<SessionSelected>(_onSessionSelected);
    on<SessionDeleted>(_onSessionDeleted);
    on<ApiBaseUrlChanged>(_onApiBaseUrlChanged);
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
          currentModel: options.current.isEmpty ? null : options.current,
        ),
      );
    }
  }

  void _onModelSelected(ModelSelected event, Emitter<ChatState> emit) {
    final model = event.model?.trim();
    if (model == null || model.isEmpty) {
      emit(state.copyWith(clearSelectedModel: true));
    } else {
      emit(state.copyWith(selectedModel: model));
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

    final result = await apiClient.sendMessage(
      agentId,
      message,
      model: state.effectiveModel,
      images: event.images,
      sessionId: _sessionId,
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

  void _onSessionSelected(SessionSelected event, Emitter<ChatState> emit) {
    if (state.isSending) return;
    _sessionId = event.sessionId;
    emit(state.copyWith(sessionId: _sessionId, turns: const []));
  }

  Future<void> _onSessionDeleted(SessionDeleted event, Emitter<ChatState> emit) async {
    final res = await apiClient.deleteSession(agentId, event.sessionId);
    if (res.isSuccess) {
      final updated = state.sessions.where((s) => s.sessionId != event.sessionId).toList();
      final bool clearingCurrent = state.sessionId == event.sessionId;
      if (clearingCurrent) {
        _sessionId = null;
      }
      emit(state.copyWith(
        sessions: updated,
        turns: clearingCurrent ? const [] : state.turns,
        clearSessionId: clearingCurrent,
      ));
    }
  }
}
