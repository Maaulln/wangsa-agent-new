import 'dart:convert';
import 'dart:typed_data';

/// Agent publik persis seperti yang diberikan API: hanya id, nama, dan
/// tujuan.
///
/// Sengaja bukan Proposal. Permukaan pengguna akhir tidak boleh punya
/// Blueprint, workspace, atau status governance untuk ditampilkan,
/// bahkan karena kecelakaan. Lihat `docs/API.md`, bagian Public Agent
/// endpoints.
class PublicAgent {
  final String id;
  final String name;
  final String purpose;

  const PublicAgent({required this.id, required this.name, required this.purpose});

  factory PublicAgent.fromJson(Map<String, dynamic> json) => PublicAgent(
        id: json['id'] as String,
        name: json['name'] as String,
        purpose: json['purpose'] as String,
      );
}

/// Informasi satu pemanggilan alat/tool yang dijalankan AI saat memproses pesan.
class ToolCallInfo {
  final String tool;
  final String preview;
  final String status;

  const ToolCallInfo({
    required this.tool,
    this.preview = '',
    this.status = 'completed',
  });

  factory ToolCallInfo.fromJson(Map<String, dynamic> json) => ToolCallInfo(
        tool: json['tool'] as String? ?? 'tool',
        preview: json['preview'] as String? ?? '',
        status: json['status'] as String? ?? 'completed',
      );

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'preview': preview,
        'status': status,
      };
}

/// Ringkasan sesi percakapan untuk drawer multi-session.
class SessionSummary {
  final String sessionId;
  final String agentId;
  final String title;
  final String lastMessage;
  final String updatedAt;
  final int turnCount;

  const SessionSummary({
    required this.sessionId,
    required this.agentId,
    required this.title,
    this.lastMessage = '',
    this.updatedAt = '',
    this.turnCount = 1,
  });

  factory SessionSummary.fromJson(Map<String, dynamic> json) => SessionSummary(
        sessionId: json['sessionId'] as String? ?? '',
        agentId: json['agentId'] as String? ?? '',
        title: json['title'] as String? ?? 'Percakapan',
        lastMessage: json['lastMessage'] as String? ?? '',
        updatedAt: json['updatedAt'] as String? ?? '',
        turnCount: (json['turnCount'] as num?)?.toInt() ?? 1,
      );
}

/// Satu giliran bicara dari riwayat sesi lampau, dari
/// `GET .../sessions/:sessionId/messages`.
///
/// Bentuknya sengaja jauh lebih sederhana daripada [AgentReply] — server
/// membaca ini langsung dari transkrip tersimpan (bukan giliran baru yang
/// baru dijawab Agent), jadi lampiran gambar/berkas/tool call giliran lama
/// tidak diikutsertakan, hanya teksnya.
class HistoryTurn {
  final String role;
  final String content;

  const HistoryTurn({required this.role, required this.content});

  bool get isUser => role == 'user';

  factory HistoryTurn.fromJson(Map<String, dynamic> json) => HistoryTurn(
        role: json['role'] as String? ?? 'agent',
        content: json['content'] as String? ?? '',
      );
}

/// Balasan satu giliran percakapan.
///
/// [sessionId] harus disimpan pemanggil dan dikirim balik pada pesan
/// berikutnya (lihat [WangsaApiClient.sendMessage]) — tanpa itu server
/// menganggap setiap pesan sebagai percakapan baru dan Agent kehilangan
/// konteks.
class AgentReply {
  final String response;
  final String sessionId;
  final String thought;
  final List<ToolCallInfo> toolCalls;

  /// Gambar yang dikirim Agent bersama balasan ini (mis. screenshot,
  /// hasil image_gen). Kosong pada sebagian besar balasan — hanya terisi
  /// bila server menyertakan kunci `images`. Lihat [ReplyImage].
  final List<ReplyImage> images;

  /// Dokumen atau audio yang dikirim Agent bersama balasan ini (mis. PDF,
  /// CSV, hasil text_to_speech). Kosong pada sebagian besar balasan —
  /// hanya terisi bila server menyertakan kunci `files`. Lihat [ReplyFile].
  final List<ReplyFile> files;

  const AgentReply({
    required this.response,
    required this.sessionId,
    this.thought = '',
    this.toolCalls = const [],
    this.images = const [],
    this.files = const [],
  });

  factory AgentReply.fromJson(Map<String, dynamic> json) {
    final rawImages = json['images'];
    final rawFiles = json['files'];
    final rawTools = json['toolCalls'];
    return AgentReply(
      response: json['response'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      thought: json['thought'] as String? ?? '',
      toolCalls: rawTools is List
          ? [
              for (final item in rawTools)
                if (item is Map<String, dynamic>) ToolCallInfo.fromJson(item),
            ]
          : const [],
      images: rawImages is List
          ? [
              for (final item in rawImages)
                if (item is Map<String, dynamic>) ReplyImage.fromJson(item),
            ]
          : const [],
      files: rawFiles is List
          ? [
              for (final item in rawFiles)
                if (item is Map<String, dynamic>) ReplyFile.fromJson(item),
            ]
          : const [],
    );
  }
}

/// Satu gambar yang dikirim Agent lewat balasan.
///
/// Server mengirim salah satu dari dua bentuk (lihat
/// `_encode_local_image` dan `send_image()` di
/// `plugins/platforms/wangsa_mobile/adapter.py`): [bytes] untuk gambar
/// lokal Agent (base64 di JSON, simetris dengan cara klien mengirim
/// [ChatImage] ke server), atau [url] untuk gambar dari tautan jarak jauh
/// yang cukup diambil langsung oleh klien lewat `Image.network`. Salah
/// satu dari keduanya selalu ada; keduanya null berarti berkas gagal
/// diuraikan dan pratinjau ditampilkan sebagai lambang rusak.
class ReplyImage {
  final Uint8List? bytes;
  final String? url;
  final String mimeType;
  final String filename;
  final String? caption;

  const ReplyImage({
    this.bytes,
    this.url,
    this.mimeType = 'image/png',
    this.filename = 'gambar.png',
    this.caption,
  });

  factory ReplyImage.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    Uint8List? decoded;
    if (data is String && data.isNotEmpty) {
      try {
        decoded = base64Decode(data);
      } catch (_) {
        decoded = null;
      }
    }
    return ReplyImage(
      bytes: decoded,
      url: json['url'] as String?,
      mimeType: json['mimeType'] as String? ?? 'image/png',
      filename: json['filename'] as String? ?? 'gambar.png',
      caption: json['caption'] as String?,
    );
  }
}

/// Satu dokumen atau audio yang dikirim Agent lewat balasan (bukan
/// gambar — lihat [ReplyImage] untuk itu).
///
/// [kind] adalah `"document"` (PDF, CSV, berkas apa pun) atau `"audio"`
/// (hasil text_to_speech) — lihat `_encode_local_file` di
/// `plugins/platforms/wangsa_mobile/adapter.py`. Klien memakainya untuk
/// memilih antara kartu berkas (bisa dibagikan) atau pemutar audio.
/// [bytes] null berarti berkas gagal diuraikan di server (mis. lebih
/// besar dari batas ukuran) — kartu tetap tampil dengan lambang rusak.
class ReplyFile {
  final Uint8List? bytes;
  final String mimeType;
  final String filename;
  final String kind;
  final String? caption;

  const ReplyFile({
    this.bytes,
    this.mimeType = 'application/octet-stream',
    this.filename = 'berkas',
    this.kind = 'document',
    this.caption,
  });

  bool get isAudio => kind == 'audio';

  factory ReplyFile.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    Uint8List? decoded;
    if (data is String && data.isNotEmpty) {
      try {
        decoded = base64Decode(data);
      } catch (_) {
        decoded = null;
      }
    }
    return ReplyFile(
      bytes: decoded,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      filename: json['filename'] as String? ?? 'berkas',
      kind: json['kind'] as String? ?? 'document',
      caption: json['caption'] as String?,
    );
  }
}

/// Satu pilihan provider yang terdaftar di konfigurasi agent/gateway.
class ProviderOption {
  final String id;
  final String name;
  final List<String> models;

  const ProviderOption({
    required this.id,
    required this.name,
    required this.models,
  });

  factory ProviderOption.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'];
    return ProviderOption(
      id: json['id'] as String? ?? json['slug'] as String? ?? '',
      name: json['name'] as String? ?? json['slug'] as String? ?? '',
      models: rawModels is List ? [for (final m in rawModels) m.toString()] : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'models': models,
      };
}

/// Daftar model dari deployment — persis seperti yang diberikan
/// `GET /api/v1/agents/:agentId/models`: provider yang sedang aktif,
/// model yang sedang aktif, model id di provider itu, dan seluruh daftar provider.
class ModelOptions {
  final String provider;
  final String current;
  final List<String> models;
  final List<ProviderOption> providers;

  const ModelOptions({
    required this.provider,
    required this.current,
    required this.models,
    this.providers = const [],
  });

  factory ModelOptions.fromJson(Map<String, dynamic> json) {
    final raw = json['models'];
    final rawProviders = json['providers'];
    return ModelOptions(
      provider: json['provider'] as String? ?? '',
      current: json['current'] as String? ?? '',
      models: raw is List ? [for (final m in raw) m.toString()] : const [],
      providers: rawProviders is List
          ? [
              for (final p in rawProviders)
                if (p is Map<String, dynamic>)
                  ProviderOption.fromJson(p)
                else if (p is Map)
                  ProviderOption.fromJson(Map<String, dynamic>.from(p)),
            ]
          : const [],
    );
  }
}

/// Satu gambar yang dilampirkan ke pesan.
///
/// [bytes] adalah isi berkas yang sudah dibaca ke memori (oleh pemilih
/// gambar), [mimeType] mis. `image/jpeg`, dan [filename] nama untuk
/// ditampilkan/diteruskan ke server.
class ChatImage {
  final List<int> bytes;
  final String mimeType;
  final String filename;

  const ChatImage({
    required this.bytes,
    this.mimeType = 'image/jpeg',
    this.filename = 'gambar.jpg',
  });
}

/// Informasi status autentikasi provider inference AI (persis seperti di hermes setup / hermes auth).
class AuthProviderItem {
  final String id;
  final String name;
  final String authType;
  final bool configured;
  final String? envVar;
  final String? keyPreview;
  final String description;
  final String helpUrl;

  const AuthProviderItem({
    required this.id,
    required this.name,
    required this.authType,
    required this.configured,
    this.envVar,
    this.keyPreview,
    this.description = "",
    this.helpUrl = "",
  });

  factory AuthProviderItem.fromJson(Map<String, dynamic> json) {
    return AuthProviderItem(
      id: json["id"] as String? ?? "",
      name: json["name"] as String? ?? "",
      authType: json["authType"] as String? ?? "api_key",
      configured: json["configured"] as bool? ?? false,
      envVar: json["envVar"] as String?,
      keyPreview: json["keyPreview"] as String?,
      description: json["description"] as String? ?? "",
      helpUrl: json["helpUrl"] as String? ?? "",
    );
  }

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "authType": authType,
        "configured": configured,
        "envVar": envVar,
        "keyPreview": keyPreview,
        "description": description,
        "helpUrl": helpUrl,
      };
}
