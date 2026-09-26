import "dart:async";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../api/models.dart";
import "../../api/wangsa_api_client.dart";

/// Halaman manajemen autentikasi provider LLM inference AI
/// Meniru alur konfigurasi provider pada `hermes setup` / `hermes auth`.
class ProviderSetupPage extends StatefulWidget {
  final WangsaApiClient apiClient;
  final VoidCallback? onCredentialsChanged;

  const ProviderSetupPage({
    super.key,
    required this.apiClient,
    this.onCredentialsChanged,
  });

  @override
  State<ProviderSetupPage> createState() => _ProviderSetupPageState();
}

class _ProviderSetupPageState extends State<ProviderSetupPage> {
  final _searchController = TextEditingController();
  bool _loading = true;
  String? _errorMessage;
  List<AuthProviderItem> _providers = [];
  String _selectedFilter = "Semua";
  String _searchQuery = "";

  static const _popularIds = {
    "opencode-free",
    "opencode-zen",
    "copilot",
    "anthropic",
    "openai-api",
    "gemini",
    "deepseek",
    "groq",
    "openrouter",
    "nous",
    "fireworks",
    "custom",
  };

  @override
  void initState() {
    super.initState();
    _fetchProviders();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchProviders() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final res = await widget.apiClient.getAuthProviders();
    if (!mounted) return;

    if (res.isSuccess) {
      setState(() {
        _providers = res.dataOrNull ?? [];
        _loading = false;
      });
    } else {
      setState(() {
        _errorMessage =
            res.errorOrNull?.message ?? "Gagal memuat daftar provider.";
        _loading = false;
      });
    }
  }

  void _openConfigDialog(AuthProviderItem provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ProviderConfigSheet(
        provider: provider,
        apiClient: widget.apiClient,
        onSuccess: () {
          _fetchProviders();
          widget.onCredentialsChanged?.call();
        },
      ),
    );
  }

  IconData _iconForProvider(String id) {
    if (id.startsWith("opencode")) return Icons.code_rounded;
    switch (id) {
      case "copilot":
      case "copilot-acp":
        return Icons.terminal_rounded;
      case "anthropic":
        return Icons.auto_awesome_rounded;
      case "openai-api":
      case "openai-codex":
        return Icons.psychology_rounded;
      case "gemini":
      case "vertex":
        return Icons.diamond_rounded;
      case "openrouter":
        return Icons.alt_route_rounded;
      case "deepseek":
        return Icons.explore_rounded;
      case "groq":
        return Icons.bolt_rounded;
      case "nous":
        return Icons.hub_rounded;
      case "fireworks":
        return Icons.local_fire_department_rounded;
      case "nvidia":
        return Icons.developer_board_rounded;
      case "huggingface":
        return Icons.sentiment_satisfied_alt_rounded;
      case "alibaba":
      case "alibaba-coding-plan":
      case "qwen-oauth":
        return Icons.cloud_done_rounded;
      case "lmstudio":
      case "ollama-cloud":
      case "custom":
        return Icons.dns_rounded;
      case "xai":
      case "xai-oauth":
        return Icons.star_border_rounded;
      case "kimi-coding":
      case "kimi-coding-cn":
        return Icons.chat_bubble_outline_rounded;
      default:
        return Icons.cloud_outlined;
    }
  }

  List<AuthProviderItem> get _filteredProviders {
    return _providers.where((p) {
      // Filter tab
      if (_selectedFilter == "Aktif" && !p.configured) {
        return false;
      }
      if (_selectedFilter == "OpenCode" && !p.id.startsWith("opencode")) {
        return false;
      }
      if (_selectedFilter == "Populer" && !_popularIds.contains(p.id)) {
        return false;
      }

      // Search query
      if (_searchQuery.isNotEmpty) {
        final matchName = p.name.toLowerCase().contains(_searchQuery);
        final matchId = p.id.toLowerCase().contains(_searchQuery);
        final matchDesc = p.description.toLowerCase().contains(_searchQuery);
        return matchName || matchId || matchDesc;
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Setup Provider & Login AI"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: "Segarkan",
            onPressed: _loading ? null : _fetchProviders,
          ),
        ],
      ),
      body: _buildBody(theme, scheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: scheme.error),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _fetchProviders,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text("Coba Lagi"),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredProviders;
    final activeCount = _providers.where((p) => p.configured).length;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "Koneksikan provider AI Anda di bawah ini dengan memasukkan API Key atau login akun (seperti pada alur hermes setup). Kredensial disimpan secara aman di backend.",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Search box
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: "Cari provider (OpenCode, Claude, OpenAI, dll.)...",
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      _searchController.clear();
                    },
                  )
                : null,
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Filter Chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildFilterChip("Semua", "Semua (${_providers.length})", scheme),
              const SizedBox(width: 8),
              _buildFilterChip("Aktif", "Aktif ($activeCount)", scheme),
              const SizedBox(width: 8),
              _buildFilterChip("OpenCode", "OpenCode", scheme),
              const SizedBox(width: 8),
              _buildFilterChip("Populer", "Populer", scheme),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Daftar Provider (${filtered.length})",
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (activeCount > 0)
              Text(
                "$activeCount aktif",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade700,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(
                  Icons.search_off_rounded,
                  size: 48,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  "Tidak ada provider yang cocok",
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else
          for (final provider in filtered) ...[
            _buildProviderCard(provider, theme, scheme),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildFilterChip(String filterKey, String label, ColorScheme scheme) {
    final isSelected = _selectedFilter == filterKey;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _selectedFilter = filterKey;
          });
        }
      },
      selectedColor: scheme.primaryContainer,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildProviderCard(
    AuthProviderItem provider,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final isConfigured = provider.configured;
    final isFree = provider.authType == "free";

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isConfigured
              ? Colors.green.withValues(alpha: 0.4)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: isConfigured
          ? Colors.green.withValues(alpha: 0.05)
          : scheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openConfigDialog(provider),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: isConfigured
                          ? Colors.green.withValues(alpha: 0.15)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _iconForProvider(provider.id),
                      color: isConfigured
                          ? Colors.green.shade700
                          : scheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                provider.name,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (isFree) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  "FREE",
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (provider.keyPreview != null &&
                            provider.keyPreview!.isNotEmpty)
                          Text(
                            provider.keyPreview!,
                            style: TextStyle(
                              fontFamily: "monospace",
                              fontSize: 12,
                              color: isConfigured
                                  ? Colors.green.shade800
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isConfigured
                          ? Colors.green.withValues(alpha: 0.15)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isConfigured
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 14,
                          color: isConfigured
                              ? Colors.green.shade700
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isFree
                              ? "Aktif (Gratis)"
                              : isConfigured
                              ? "Terhubung"
                              : "Belum aktif",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isConfigured
                                ? Colors.green.shade800
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (provider.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  provider.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderConfigSheet extends StatefulWidget {
  final AuthProviderItem provider;
  final WangsaApiClient apiClient;
  final VoidCallback onSuccess;

  const _ProviderConfigSheet({
    required this.provider,
    required this.apiClient,
    required this.onSuccess,
  });

  @override
  State<_ProviderConfigSheet> createState() => _ProviderConfigSheetState();
}

class _ProviderConfigSheetState extends State<_ProviderConfigSheet> {
  final _keyController = TextEditingController();
  final _urlController = TextEditingController();
  final _modelController = TextEditingController();
  final _nameController = TextEditingController();

  bool _obscureKey = true;
  bool _submitting = false;
  String? _statusError;

  // Copilot device flow state
  bool _copilotDeviceMode = true;
  String? _copilotUserCode;
  String? _copilotDeviceCode;
  String? _copilotUri;
  Timer? _copilotPollTimer;
  bool _copilotPolling = false;

  @override
  void initState() {
    super.initState();
    if (widget.provider.id == "custom") {
      _nameController.text = "Ollama Lokal";
      _urlController.text = "http://localhost:11434/v1";
      _modelController.text = "llama3:8b";
    }
  }

  @override
  void dispose() {
    _copilotPollTimer?.cancel();
    _keyController.dispose();
    _urlController.dispose();
    _modelController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData("text/plain");
    if (data?.text != null && mounted) {
      setState(() {
        _keyController.text = data!.text!.trim();
      });
    }
  }

  void _copyToClipboard(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _startCopilotDeviceFlow() async {
    setState(() {
      _submitting = true;
      _statusError = null;
    });

    final res = await widget.apiClient.startCopilotDeviceCode();
    if (!mounted) return;

    if (res.isSuccess) {
      final data = res.dataOrNull ?? {};
      final rawData = data["data"] is Map<String, dynamic>
          ? data["data"] as Map<String, dynamic>
          : data;
      setState(() {
        _submitting = false;
        _copilotUserCode = rawData["user_code"] as String?;
        _copilotDeviceCode = rawData["device_code"] as String?;
        _copilotUri =
            rawData["verification_uri"] as String? ??
            "https://github.com/login/device";
        _copilotPolling = true;
      });
      _startCopilotPolling();
    } else {
      setState(() {
        _submitting = false;
        _statusError =
            res.errorOrNull?.message ?? "Gagal memulai otorisasi GitHub.";
      });
    }
  }

  void _startCopilotPolling() {
    _copilotPollTimer?.cancel();
    _copilotPollTimer = Timer.periodic(const Duration(seconds: 4), (
      timer,
    ) async {
      if (!mounted || _copilotDeviceCode == null) {
        timer.cancel();
        return;
      }

      final pollRes = await widget.apiClient.pollCopilotDeviceCode(
        _copilotDeviceCode!,
      );
      if (!mounted) return;

      if (pollRes.isSuccess) {
        final data = pollRes.dataOrNull ?? {};
        final rawData = data["data"] is Map<String, dynamic>
            ? data["data"] as Map<String, dynamic>
            : data;
        final status = rawData["status"] as String?;

        if (status == "ready") {
          timer.cancel();
          setState(() {
            _copilotPolling = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("GitHub Copilot berhasil terhubung!")),
          );
          widget.onSuccess();
          Navigator.of(context).pop();
        } else if (status == "error") {
          timer.cancel();
          setState(() {
            _copilotPolling = false;
            _statusError =
                rawData["message"] as String? ?? "Gagal memverifikasi token.";
          });
        }
      }
    });
  }

  Future<void> _submitForm() async {
    final isCustom = widget.provider.id == "custom";
    final isCopilot = widget.provider.id == "copilot";

    final String? apiKeyVal = isCustom
        ? (_keyController.text.trim().isNotEmpty
              ? _keyController.text.trim()
              : null)
        : (isCopilot ? null : _keyController.text.trim());
    final String? tokenVal = (isCopilot && !_copilotDeviceMode)
        ? _keyController.text.trim()
        : null;
    final String? nameVal = isCustom
        ? (_nameController.text.trim().isNotEmpty
              ? _nameController.text.trim()
              : "Custom")
        : null;
    final String? baseUrlVal = isCustom ? _urlController.text.trim() : null;
    final String? modelVal = isCustom ? _modelController.text.trim() : null;

    if (isCustom && (baseUrlVal == null || baseUrlVal.isEmpty)) {
      setState(() => _statusError = "Base URL wajib diisi.");
      return;
    }
    if (isCopilot &&
        !_copilotDeviceMode &&
        (tokenVal == null || tokenVal.isEmpty)) {
      setState(() => _statusError = "GitHub Token wajib diisi.");
      return;
    }
    if (!isCustom && !isCopilot && (apiKeyVal == null || apiKeyVal.isEmpty)) {
      setState(() => _statusError = "Kunci API tidak boleh kosong.");
      return;
    }

    setState(() {
      _submitting = true;
      _statusError = null;
    });

    final res = await widget.apiClient.saveProviderCredentials(
      widget.provider.id,
      apiKey: apiKeyVal,
      token: tokenVal,
      name: nameVal,
      baseUrl: baseUrlVal,
      model: modelVal,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (res.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.dataOrNull ?? "Kredensial berhasil disimpan."),
        ),
      );
      widget.onSuccess();
      Navigator.of(context).pop();
    } else {
      setState(() {
        _statusError =
            res.errorOrNull?.message ?? "Gagal menyimpan kredensial.";
      });
    }
  }

  Future<void> _deleteCredentials() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Putuskan ${widget.provider.name}?"),
        content: const Text(
          "Kredensial atau API key yang tersimpan akan dihapus dari server.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Batal"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text("Hapus / Putuskan"),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() {
      _submitting = true;
      _statusError = null;
    });

    final res = await widget.apiClient.deleteProviderCredentials(
      widget.provider.id,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (res.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.dataOrNull ?? "Kredensial berhasil dihapus."),
        ),
      );
      widget.onSuccess();
      Navigator.of(context).pop();
    } else {
      setState(() {
        _statusError =
            res.errorOrNull?.message ?? "Gagal menghapus kredensial.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isCopilot = widget.provider.id == "copilot";
    final isCustom = widget.provider.id == "custom";
    final isFree = widget.provider.authType == "free";

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isFree
                        ? widget.provider.name
                        : "Hubungkan ${widget.provider.name}",
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.provider.description,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            if (widget.provider.helpUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text("Salin tautan pendaftaran"),
                onPressed: () => _copyToClipboard(
                  widget.provider.helpUrl,
                  "Tautan disalin: ${widget.provider.helpUrl}",
                ),
              ),
            ],
            if (_statusError != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _statusError!,
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
            // Special view for free/keyless provider (like OpenCode Free)
            if (isFree) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: Colors.green.shade700,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Provider Siap Digunakan Tanpa Kunci",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade900,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "${widget.provider.name} bersifat keyless dan tidak memerlukan API key atau akun. Model gratis yang tersedia diperbarui dari katalog provider dan dapat dipilih dari menu model di chat.",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.green.shade800,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.done_rounded),
                  label: const Text("Tutup"),
                ),
              ),
            ] else if (isCopilot) ...[
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text("Device Login"),
                    icon: Icon(Icons.qr_code_rounded),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text("Manual Token"),
                    icon: Icon(Icons.vpn_key_rounded),
                  ),
                ],
                selected: {_copilotDeviceMode},
                onSelectionChanged: (set) {
                  setState(() => _copilotDeviceMode = set.first);
                },
              ),
              const SizedBox(height: 16),
              if (_copilotDeviceMode) ...[
                if (_copilotUserCode == null) ...[
                  Text(
                    "Otorisasi cepat via browser akun GitHub Anda menggunakan Device Flow.",
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _submitting ? null : _startCopilotDeviceFlow,
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.login_rounded),
                    label: const Text("Mulai Login GitHub"),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Kode Verifikasi Anda:",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              _copilotUserCode!,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                                color: scheme.primary,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.copy_rounded),
                              tooltip: "Salin Kode",
                              onPressed: () => _copyToClipboard(
                                _copilotUserCode!,
                                "Kode ${_copilotUserCode!} disalin",
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Buka ${_copilotUri ?? 'https://github.com/login/device'} di browser, lalu masukkan kode di atas untuk menyelesaikan login.",
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(
                                Icons.open_in_browser_rounded,
                                size: 16,
                              ),
                              label: const Text("Buka Tautan"),
                              onPressed: () => _copyToClipboard(
                                _copilotUri ??
                                    "https://github.com/login/device",
                                "Tautan verifikasi disalin",
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (_copilotPolling)
                              const Row(
                                children: [
                                  SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    "Menunggu...",
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ] else ...[
                TextField(
                  controller: _keyController,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: "GitHub Personal Access Token / Token Copilot",
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            _obscureKey
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () =>
                              setState(() => _obscureKey = !_obscureKey),
                        ),
                        IconButton(
                          icon: const Icon(Icons.paste_rounded),
                          tooltip: "Tempel",
                          onPressed: _pasteFromClipboard,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitting ? null : _submitForm,
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text("Simpan Token"),
                ),
              ],
            ] else if (isCustom) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: "Nama Provider / Server",
                  hintText: "Misal: Ollama Server, vLLM",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: "Base URL (OpenAI-compatible)",
                  hintText: "http://192.168.1.100:11434/v1",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: "Default Model",
                  hintText: "llama3, mistral, dll.",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: "API Key (Opsional untuk server lokal)",
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureKey ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _submitting ? null : _submitForm,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text("Simpan Konfigurasi Custom"),
              ),
            ] else ...[
              const SizedBox(height: 16),
              TextField(
                controller: _keyController,
                obscureText: _obscureKey,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: "API Key untuk ${widget.provider.name}",
                  hintText: widget.provider.envVar != null
                      ? "Disimpan ke variabel ${widget.provider.envVar}"
                      : "Masukkan kunci API...",
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _obscureKey ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                      ),
                      IconButton(
                        icon: const Icon(Icons.paste_rounded),
                        tooltip: "Tempel",
                        onPressed: _pasteFromClipboard,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _submitting ? null : _submitForm,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text("Simpan API Key"),
              ),
            ],
            if (widget.provider.configured && !isFree) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _submitting ? null : _deleteCredentials,
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text("Putuskan / Hapus Kredensial"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
