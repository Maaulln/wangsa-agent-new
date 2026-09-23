/// Kontrak antara layar dan segala hal yang berhubungan dengan suara.
///
/// Ini batas antar tim, bukan sekadar abstraksi demi abstraksi. Layar
/// chat hanya tahu antarmuka ini. Implementasi pertama memakai
/// pengenalan suara bawaan perangkat; implementasi wake word yang
/// bersandar pada Porcupine dan layanan latar depan Android dapat
/// mengisi antarmuka yang sama tanpa mengubah satu baris pun di layar.
///
/// Aturan mikrofon yang wajib dipatuhi setiap implementasi: hanya satu
/// komponen boleh memegang mikrofon pada satu waktu. Saat
/// [startListening] dipanggil, pengawasan kata pemicu harus dihentikan
/// lebih dulu; saat [stop] selesai, pengawasan itu dinyalakan kembali.
/// Tanpa aturan ini, mesin kata pemicu dan mesin pengenalan suara
/// berebut mikrofon dan keduanya gagal.
library;

enum VoiceStatus {
  /// Tidak ada izin, tidak didukung, atau memang dimatikan pengguna.
  off,

  /// Mengawasi kata pemicu, belum merekam ucapan.
  idle,

  /// Sedang merekam ucapan pengguna.
  listening,

  /// Ucapan selesai, hasilnya sedang dirapikan.
  processing,
}

sealed class VoiceEvent {
  const VoiceEvent();
}

/// Kata pemicu terdengar. Satu-satunya kejadian yang boleh membangunkan
/// layar dari keadaan tidak aktif.
final class WakeWordDetected extends VoiceEvent {
  const WakeWordDetected();
}

/// Hasil sementara, masih bisa berubah. Berguna untuk memperlihatkan
/// bahwa aplikasi benar-benar mendengar.
final class PartialTranscript extends VoiceEvent {
  final String text;
  const PartialTranscript(this.text);
}

/// Hasil akhir satu giliran bicara. Inilah yang layak dikirim ke Agent.
final class FinalTranscript extends VoiceEvent {
  final String text;
  const FinalTranscript(this.text);
}

/// Kegagalan yang aman ditunjukkan ke pengguna. Tidak pernah berisi
/// jejak tumpukan atau pesan mentah dari pustaka di bawahnya.
final class VoiceFailure extends VoiceEvent {
  final String message;
  const VoiceFailure(this.message);
}

/// Level volume mikrofon terkini selama merekam ucapan, dinormalisasi ke
/// 0.0 (diam) - 1.0 (keras). Murni kosmetik untuk menganimasikan
/// `VoiceOrb` — tidak pernah mempengaruhi transkrip atau keputusan apa
/// pun, aman diabaikan oleh kode yang tidak peduli tampilan.
final class SoundLevelChanged extends VoiceEvent {
  final double level;
  const SoundLevelChanged(this.level);
}

abstract interface class VoiceInput {
  Stream<VoiceEvent> get events;
  VoiceStatus get status;

  /// Mulai mengawasi kata pemicu. Tidak merekam ucapan.
  Future<void> startWakeWordWatch();

  /// Mematikan pengawasan kata pemicu tanpa mematikan seluruh lapisan
  /// suara — dipakai sakelar "Dengar di latar belakang" di layar
  /// pengaturan saat pengguna memang ingin mematikannya, bukan sekadar
  /// jeda sebentar. Beda dari [stop]: [stop] menghentikan SESI DIKTE yang
  /// sedang berjalan lalu menyalakan kembali pengawasan kata pemicu;
  /// method ini justru mematikan pengawasan itu sendiri sampai
  /// [startWakeWordWatch] dipanggil lagi secara eksplisit. Aman dipanggil
  /// walau pengawasan sedang tidak aktif.
  Future<void> stopWakeWordWatch();

  /// Mulai merekam ucapan. Implementasi wajib menghentikan pengawasan
  /// kata pemicu lebih dulu.
  ///
  /// Ucapan yang menghasilkan [FinalTranscript] berisi memulai PERCAKAPAN
  /// SUARA: pengawasan kata pemicu tetap mati sampai percakapan berakhir,
  /// dan layar wajib menutupnya dengan [speakReply] (balasan datang) atau
  /// [endConversation] (balasan gagal atau dibatalkan). Percakapan juga
  /// berakhir sendiri bila ucapan kosong, atau tidak ada ucapan di sesi
  /// lanjutan; saat itu pengawasan kata pemicu dinyalakan kembali otomatis
  /// bila sebelumnya aktif.
  Future<void> startListening();

  /// Membacakan [text] (Markdown dibersihkan dulu) lalu, setelah suaranya
  /// SELESAI, membuka mikrofon lagi untuk lanjutan. Tidak melakukan apa
  /// pun bila tidak ada percakapan suara — mis. balasan untuk pesan yang
  /// diketik tidak dibacakan. Kembali setelah mikrofon lanjutan menyala,
  /// atau segera bila percakapan dihentikan selagi Agent bicara.
  Future<void> speakReply(String text);

  /// Mengakhiri percakapan suara tanpa membacakan apa pun dan menyalakan
  /// kembali pengawasan kata pemicu bila sebelumnya aktif. Tidak
  /// melakukan apa pun bila tidak ada percakapan suara, supaya tidak
  /// menyalakan kata pemicu yang sengaja dimatikan pengguna.
  Future<void> endConversation();

  /// Berhenti merekam dan kembali mengawasi kata pemicu bila sebelumnya
  /// aktif.
  Future<void> stop();

  Future<void> dispose();
}
