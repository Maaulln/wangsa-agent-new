/// Konfigurasi yang dibaca aplikasi saat dibuka, bukan yang ditanam saat
/// membangun aplikasi.
///
/// Alasannya satu: mengganti Agent yang dituju, memindahkan alamat API,
/// atau mengubah kata pemicu tidak boleh menuntut membangun ulang dan
/// memasang ulang aplikasi. Lihat `apps/mobile/PRD.md` butir 6 pada
/// bagian lingkup.
class AppConfig {
  static const String defaultWakeWord = 'porcupine';

  final String apiBaseUrl;
  final String defaultAgentId;
  final String wakeWord;

  /// AccessKey Picovoice untuk kata pemicu. Beda dari [apiBaseUrl] dan
  /// [defaultAgentId]: bukan kredensial rahasia (lihat
  /// docs/wake-word-setup-mobile.md — Picovoice sendiri menyebutnya
  /// "necessarily visible"), tapi tetap dibaca dari sini, bukan ditanam
  /// saat build, supaya rotasi AccessKey tidak menuntut pemasangan ulang
  /// aplikasi. Null berarti wake word memang belum dikonfigurasi untuk
  /// pemasangan ini — [NativeVoiceInput] tidak pernah menyalakan
  /// pengawasan kata pemicu dalam keadaan itu, persis seperti
  /// `missing_configuration` di versi web.
  final String? wakeWordAccessKey;

  const AppConfig({
    required this.apiBaseUrl,
    required this.defaultAgentId,
    this.wakeWord = defaultWakeWord,
    this.wakeWordAccessKey,
  });

  /// Melempar [FormatException] bila berkas konfigurasi tidak layak
  /// dipakai. Sengaja gagal keras: aplikasi yang berjalan dengan alamat
  /// API kosong hanya akan menampilkan galat jaringan yang membingungkan,
  /// jauh dari penyebab aslinya.
  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final apiBaseUrl = _requireText(json['apiBaseUrl'], 'apiBaseUrl');
    final defaultAgentId = _requireText(json['defaultAgentId'], 'defaultAgentId');
    final wakeWord = json['wakeWord'];
    final wakeWordAccessKey = json['wakeWordAccessKey'];

    return AppConfig(
      apiBaseUrl: _trimTrailingSlash(apiBaseUrl),
      defaultAgentId: defaultAgentId,
      wakeWord: wakeWord is String && wakeWord.trim().isNotEmpty
          ? wakeWord.trim()
          : defaultWakeWord,
      // Tidak ada nilai bawaan yang masuk akal untuk sebuah AccessKey —
      // beda dari wakeWord, kosong di sini berarti fitur mati, bukan
      // "pakai contoh punya siapa saja".
      wakeWordAccessKey: wakeWordAccessKey is String && wakeWordAccessKey.trim().isNotEmpty
          ? wakeWordAccessKey.trim()
          : null,
    );
  }

  static String _requireText(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Konfigurasi tidak memuat $field yang sah.');
    }
    return value.trim();
  }

  static String _trimTrailingSlash(String value) {
    var result = value;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  AppConfig copyWith({
    String? apiBaseUrl,
    String? defaultAgentId,
    String? wakeWord,
    String? wakeWordAccessKey,
  }) =>
      AppConfig(
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        defaultAgentId: defaultAgentId ?? this.defaultAgentId,
        wakeWord: wakeWord ?? this.wakeWord,
        wakeWordAccessKey: wakeWordAccessKey ?? this.wakeWordAccessKey,
      );
}
