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

/// Pengguna menekan "Percakapan baru". Hanya mengosongkan giliran yang
/// ada di memori — belum ada penyimpanan riwayat percakapan di backend
/// untuk dihapus atau diarsipkan, jadi ini murni mulai dari kosong lagi
/// dengan Agent yang sama.
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
