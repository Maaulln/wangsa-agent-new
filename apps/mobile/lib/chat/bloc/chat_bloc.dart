import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../api/models.dart';
import '../../api/wangsa_api_client.dart';

part 'chat_event.dart';
part 'chat_state.dart';

/// Satu-satunya pemegang keadaan percakapan.
///
/// Sengaja tidak tahu apa-apa soal Proposal, Blueprint, workspace, atau
/// persetujuan. Batas itu dijaga di backend, dan aplikasi ini tidak
/// boleh menjadi celahnya. Lihat `apps/mobile/PRD.md` bagian di luar
/// lingkup.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final WangsaApiClient apiClient;
  final String agentId;

  /// Menandai giliran kirim yang sedang berjalan. [cancelSend] menaikkan
  /// nilainya; kalau balasan `sendMessage` yang tertunda akhirnya datang
  /// (atau gagal karena kliennya baru saja ditutup) dan nilainya sudah
  /// tidak cocok lagi, `_onMessageSubmitted` tahu giliran itu sudah
  /// dibatalkan dan berhenti tanpa menimpa state dengan galat palsu.
  int _activeSendId = 0;

  /// sessionId percakapan saat ini, dari balasan Agent pertama. Null berarti
  /// pesan berikutnya memulai percakapan baru di server. Lihat
  /// `WangsaApiClient.sendMessage` — tanpa nilai ini dikirim balik, server
  /// memperlakukan setiap pesan sebagai percakapan baru dan Agent kehilangan
  /// konteks.
  String? _sessionId;

  ChatBloc({required this.apiClient, required this.agentId})
      : super(const ChatState()) {
    on<ChatOpened>(_onOpened);
    on<MessageSubmitted>(_onMessageSubmitted);
    on<ModelSelected>(_onModelSelected);
    on<ConversationCleared>(_onConversationCleared);
    on<MessageCancelled>(_onMessageCancelled);
  }

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    emit(state.copyWith(status: ChatStatus.loading, clearError: true));

    final result = await apiClient.getAgent(agentId);

    if (!result.isSuccess) {
      // API menjawab 404 yang sama persis untuk Agent yang tidak ada, yang
      // belum dipublikasikan, yang masih menunggu, dan yang ditolak.
      // Layar ini memang tidak tahu yang mana, dan itu justru maksudnya.
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

    // Daftar model bukan fatal: gagal dimuat berarti pemilih model
    // menampilkan keadaan kosong dan kirim tetap memakai bawaan server.
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
    // Giliran ini sudah dibatalkan lewat cancelSend() selagi menunggu —
    // state sudah diurus di sana, jangan timpa lagi dengan galat palsu
    // dari koneksi yang memang sengaja diputus.
    if (sendId != _activeSendId) return;
    final reply = result.dataOrNull;

    if (result.isSuccess && reply != null) {
      if (reply.sessionId.isNotEmpty) {
        _sessionId = reply.sessionId;
      }
      emit(
        state.copyWith(
          turns: [
            ...withUserTurn,
            Turn(
              role: TurnRole.agent,
              content: reply.response,
              images: reply.images,
              files: reply.files,
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
    emit(state.copyWith(turns: const [], clearError: true));
  }

  void _onMessageCancelled(MessageCancelled event, Emitter<ChatState> emit) {
    if (!state.isSending) return;
    _activeSendId++;
    apiClient.cancelInFlight();
    emit(state.copyWith(isSending: false));
  }
}
