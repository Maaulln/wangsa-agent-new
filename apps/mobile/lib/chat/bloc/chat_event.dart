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

/// Pengguna memilih model lewat pil model. Null berarti kembali ke
/// bawaan (model aktif server).
final class ModelSelected extends ChatEvent {
  final String? model;

  const ModelSelected(this.model);

  @override
  List<Object?> get props => [model];
}

/// Pengguna menekan "Percakapan baru".
final class ConversationCleared extends ChatEvent {
  const ConversationCleared();
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

/// Memilih/berpindah ke sesi lain dari drawer.
final class SessionSelected extends ChatEvent {
  final String sessionId;

  const SessionSelected(this.sessionId);

  @override
  List<Object?> get props => [sessionId];
}

/// Menghapus sesi tertentu dari drawer.
final class SessionDeleted extends ChatEvent {
  final String sessionId;

  const SessionDeleted(this.sessionId);

  @override
  List<Object?> get props => [sessionId];
}

/// Alamat API backend diubah dari Pengaturan.
final class ApiBaseUrlChanged extends ChatEvent {
  final String newUrl;

  const ApiBaseUrlChanged(this.newUrl);

  @override
  List<Object?> get props => [newUrl];
}
