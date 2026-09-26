part of 'chat_bloc.dart';

sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => const [];
}

/// Layar dibuka. Memuat nama dan tujuan Agent.
final class ChatOpened extends ChatEvent {
  const ChatOpened();
}

/// Satu giliran bicara dari pengguna, entah diketik atau hasil ucapan.
/// Sengaja satu event untuk kedua jalur masuk: begitu suara sudah jadi
/// teks, tidak ada lagi perbedaan yang perlu diketahui layar.
///
/// [images] gambar yang sudah dibaca ke memori; teks boleh kosong bila
/// ada gambar (pesan foto tanpa caption).
final class MessageSubmitted extends ChatEvent {
  final String message;
  final List<ChatImage> images;

  const MessageSubmitted(this.message, {this.images = const []});

  @override
  List<Object?> get props => [message, images];
}

/// Mengulang kiriman terakhir yang gagal dengan prompt dan lampiran yang sama.
final class MessageRetried extends ChatEvent {
  const MessageRetried();
}

/// Pengguna memilih model lewat pil model. Null berarti kembali ke
/// bawaan (model aktif server).
final class ModelSelected extends ChatEvent {
  final String? model;
  final String? provider;

  const ModelSelected(this.model, {this.provider});

  @override
  List<Object?> get props => [model, provider];
}

/// Kapabilitas chat untuk percakapan baru. Pilihan dikunci setelah pesan
/// pertama supaya tool schema stabil sepanjang sesi.
final class ToolsetsSelected extends ChatEvent {
  final List<String> toolsets;

  const ToolsetsSelected(this.toolsets);

  @override
  List<Object?> get props => [toolsets];
}

/// Pengguna menekan "Percakapan baru".
final class ConversationCleared extends ChatEvent {
  const ConversationCleared();
}

/// Starts an agent-design conversation from the dedicated mobile workspace.
/// This asks the configured assistant to draft a plan; it does not publish an
/// agent because the mobile gateway API has no blueprint/publish endpoint.
final class AgentBuildRequested extends ChatEvent {
  final String brief;
  const AgentBuildRequested(this.brief);

  @override
  List<Object?> get props => [brief];
}

/// Pengguna menekan tombol stop selagi Agent sedang membalas. Event
/// terpisah dari [MessageSubmitted] — keduanya berjalan di langganan
/// Bloc yang independen, sehingga event ini tetap segera ditangani
/// walau `_onMessageSubmitted` masih tertahan menunggu jawaban server,
/// bukan mengantre di belakangnya.
final class MessageCancelled extends ChatEvent {
  const MessageCancelled();
}

/// Memuat riwayat sesi untuk drawer.
final class SessionsRequested extends ChatEvent {
  const SessionsRequested();
}

/// Memilih sesi percakapan dari drawer.
final class SessionSelected extends ChatEvent {
  final String sessionId;

  const SessionSelected(this.sessionId);

  @override
  List<Object?> get props => [sessionId];
}

/// Menghapus sesi percakapan dari drawer.
final class SessionDeleted extends ChatEvent {
  final String sessionId;

  const SessionDeleted(this.sessionId);

  @override
  List<Object?> get props => [sessionId];
}

/// Alamat host server diubah lewat pengaturan.
final class ApiBaseUrlChanged extends ChatEvent {
  final String newUrl;

  const ApiBaseUrlChanged(this.newUrl);

  @override
  List<Object?> get props => [newUrl];
}

/// Memuat ulang daftar model dan provider dari server.
final class ModelsRequested extends ChatEvent {
  const ModelsRequested();
}

/// Memuat ulang status Connect LLM (profile + configured) dari server.
/// Dipanggil setelah ChatOpened dan setiap kembali dari layar Setup Provider.
final class SetupStatusRequested extends ChatEvent {
  const SetupStatusRequested();
}
