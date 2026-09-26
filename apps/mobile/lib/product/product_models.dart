class ProductUser {
  final String id;
  final String username;
  const ProductUser({required this.id, required this.username});
  factory ProductUser.fromJson(Map<String, dynamic> json) => ProductUser(
    id: json['id'] as String,
    username: json['username'] as String,
  );
}

class ProductProvider {
  final bool configured;
  final String? provider;
  final String? model;
  const ProductProvider({this.configured = false, this.provider, this.model});
  factory ProductProvider.fromJson(Map<String, dynamic> json) =>
      ProductProvider(
        configured: json['configured'] == true,
        provider: json['provider'] as String?,
        model: json['model'] as String?,
      );
}

class ProductProviderOption {
  final String id;
  final String name;
  final bool requiresApiKey;
  const ProductProviderOption({
    required this.id,
    required this.name,
    this.requiresApiKey = true,
  });
  factory ProductProviderOption.fromJson(Map<String, dynamic> json) =>
      ProductProviderOption(
        id: json['id'] as String,
        name: json['name'] as String,
        requiresApiKey: json['requires_api_key'] != false,
      );
}

class ProductModelCatalog {
  final List<String> models;
  final String source;
  const ProductModelCatalog({required this.models, required this.source});
  factory ProductModelCatalog.fromJson(Map<String, dynamic> json) =>
      ProductModelCatalog(
        models: [
          for (final item in json['models'] as List? ?? []) item as String,
        ],
        source: json['source'] as String? ?? 'curated',
      );
}

class JobEvent {
  final String message;
  final String createdAt;
  const JobEvent({required this.message, required this.createdAt});
  factory JobEvent.fromJson(Map<String, dynamic> json) => JobEvent(
    message: json['message'] as String? ?? '',
    createdAt: json['created_at'] as String? ?? '',
  );
}

class ProductJob {
  final String id;
  final String title;
  final String prompt;
  final String status;
  final String? report;
  final String? question;
  final String? error;
  final String? skillId;
  final String createdAt;
  final String updatedAt;
  final List<JobEvent> events;
  const ProductJob({
    required this.id,
    required this.title,
    required this.prompt,
    required this.status,
    this.report,
    this.question,
    this.error,
    this.skillId,
    this.createdAt = '',
    this.updatedAt = '',
    this.events = const [],
  });
  bool get isActive =>
      const ['queued', 'running', 'needs_input'].contains(status);
  String get statusLabel =>
      const {
        'queued': 'Dalam antrean',
        'running': 'Sedang dikerjakan',
        'needs_input': 'Perlu jawabanmu',
        'completed': 'Selesai',
        'failed': 'Belum berhasil',
        'cancelled': 'Dibatalkan',
      }[status] ??
      status;
  factory ProductJob.fromJson(Map<String, dynamic> json) => ProductJob(
    id: json['id'] as String,
    title: json['title'] as String? ?? 'Pekerjaan',
    prompt: json['prompt'] as String? ?? '',
    status: json['status'] as String,
    report: json['report'] as String?,
    question: json['question'] as String?,
    error: json['error'] as String?,
    skillId: json['skill_id'] as String?,
    createdAt: json['created_at'] as String? ?? '',
    updatedAt: json['updated_at'] as String? ?? '',
    events: [
      for (final item in json['events'] as List? ?? [])
        JobEvent.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
  );
}

class ProductSkill {
  final String id;
  final String name;
  final String description;
  final String content;
  final String status;
  final int version;
  final String? sourceJobId;
  const ProductSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.status,
    required this.version,
    this.sourceJobId,
  });
  factory ProductSkill.fromJson(Map<String, dynamic> json) => ProductSkill(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    content: json['content'] as String? ?? '',
    status: json['status'] as String,
    version: (json['version'] as num?)?.toInt() ?? 1,
    sourceJobId: json['source_job_id'] as String?,
  );
}
