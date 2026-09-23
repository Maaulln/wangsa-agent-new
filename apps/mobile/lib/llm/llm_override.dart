/// Override LLM per-permintaan milik pengguna (BYOK) yang dikirim ke
/// `POST /api/v1/agents/:agentId/messages` sebagai objek `llm`.
///
/// Absen (null di controller) berarti memakai model deployment (default
/// Gemma — lihat `DEFAULT_LLM_MODEL` di apps/api/src/config.ts). Kunci
/// ini transit lewat backend (backend yang memanggil provider) — lihat
/// catatan keamanan di `LlmSettingsController`.
class LlmOverride {
  /// Endpoint OpenAI-compatible, mis. `https://api.openai.com/v1`.
  final String baseURL;

  /// Kunci API milik pengguna di provider itu.
  final String apiKey;

  /// Id model di provider itu, mis. `gpt-4o-mini`.
  final String model;

  const LlmOverride({
    required this.baseURL,
    required this.apiKey,
    required this.model,
  });

  Map<String, String> toJson() => {'baseURL': baseURL, 'apiKey': apiKey, 'model': model};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmOverride &&
          other.baseURL == baseURL &&
          other.apiKey == apiKey &&
          other.model == model;

  @override
  int get hashCode => Object.hash(baseURL, apiKey, model);
}
