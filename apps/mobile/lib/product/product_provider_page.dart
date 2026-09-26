import 'dart:async';

import 'package:flutter/material.dart';
import 'product_api.dart';
import 'product_models.dart';
import 'product_session.dart';
import 'product_widgets.dart';

class ProductProviderPage extends StatefulWidget {
  final ProductSession session;
  final bool onboarding;
  final VoidCallback? onSaved;
  const ProductProviderPage({
    super.key,
    required this.session,
    this.onboarding = false,
    this.onSaved,
  });
  @override
  State<ProductProviderPage> createState() => _ProductProviderPageState();
}

class _ProductProviderPageState extends State<ProductProviderPage> {
  final _form = GlobalKey<FormState>();
  final _model = TextEditingController();
  final _key = TextEditingController();
  String _provider = 'openai';
  List<ProductProviderOption> _providers = const [];
  List<String> _models = const [];
  String _modelsSource = '';
  String? _modelNotice;
  int _modelPickerRevision = 0;
  bool _discoveringModels = false;
  bool _busy = false;
  String? _error;
  ProductProviderOption? get _selectedProvider {
    for (final provider in _providers) {
      if (provider.id == _provider) return provider;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _provider = widget.session.provider?.provider ?? 'openai';
    _model.text = widget.session.provider?.model ?? '';
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    try {
      final providers = await widget.session.run(
        widget.session.api.providerCatalog,
      );
      if (!mounted) return;
      final savedSelection =
          widget.session.provider?.configured == true &&
          widget.session.provider?.provider == _provider;
      final keylessSelection = providers.any(
        (item) => item.id == _provider && !item.requiresApiKey,
      );
      setState(() {
        _providers = providers;
        if (!providers.any((item) => item.id == _provider) &&
            providers.isNotEmpty) {
          _provider = providers.first.id;
        }
      });
      if (savedSelection || keylessSelection) {
        await _discoverModels(silent: true);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Daftar provider belum bisa dimuat. Coba lagi.',
        );
      }
    }
  }

  Future<void> _discoverModels({bool silent = false}) async {
    final selection = _selectedProvider;
    if (_discoveringModels || selection == null) return;
    setState(() {
      _discoveringModels = true;
      if (!silent) _error = null;
    });
    try {
      final catalog = await widget.session.run(
        () => widget.session.api.discoverModels(
          _provider,
          apiKey: selection.requiresApiKey ? _key.text.trim() : '',
        ),
      );
      if (mounted) {
        setState(() {
          final liveOpenCodeCatalog =
              _provider != 'opencode-free' || catalog.source == 'live';
          _models = liveOpenCodeCatalog ? catalog.models : const [];
          _modelsSource = catalog.source;
          final currentModel = _model.text.trim();
          if (_provider == 'opencode-free' && !liveOpenCodeCatalog) {
            _model.clear();
            _modelPickerRevision++;
            _modelNotice =
                'Katalog live OpenCode Free belum tersedia. Deteksi model lagi sebelum menyimpan.';
          } else if (_provider == 'opencode-free' &&
              currentModel.isNotEmpty &&
              !_models.contains(currentModel)) {
            _model.clear();
            _modelPickerRevision++;
            _modelNotice =
                'Model $currentModel sudah tidak tersedia. Pilih model OpenCode Free dari daftar terbaru.';
          } else {
            _modelNotice = null;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _models = const [];
          _modelsSource = '';
          if (_provider == 'opencode-free') {
            if (_model.text.isNotEmpty) {
              _model.clear();
              _modelPickerRevision++;
            }
            _modelNotice =
                'Katalog live OpenCode Free belum tersedia. Deteksi model lagi sebelum menyimpan.';
            if (!silent) {
              _error = 'Katalog OpenCode Free belum bisa dimuat. Coba lagi.';
            }
          } else if (!silent) {
            _error =
                'Model belum bisa dideteksi. Kamu tetap bisa mengisi ID model manual.';
          }
        });
      }
    } finally {
      if (mounted) setState(() => _discoveringModels = false);
    }
  }

  @override
  void dispose() {
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.run(
        () => widget.session.api.saveProvider(
          _provider,
          _model.text.trim(),
          _key.text.trim(),
        ),
      );
      _key.clear();
      await widget.session.refreshProvider();
      if (mounted) {
        widget.onSaved?.call();
        if (!widget.onboarding) Navigator.of(context).pop();
      }
    } on ProductApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Provider belum tersimpan. Coba lagi.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.onboarding ? 'Hubungkan AI milikmu' : 'Pengaturan provider',
      ),
    ),
    body: SafeArea(
      child: ProductBody(
        children: [
          Text(
            'Pilih AI untuk pekerjaanmu',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            _selectedProvider?.requiresApiKey == false
                ? 'Provider gratis ini tidak memerlukan API key.'
                : 'Gunakan API key milikmu. Penggunaan model mengikuti ketentuan provider.',
          ),
          const SizedBox(height: 28),
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _providers.any((item) => item.id == _provider)
                      ? _provider
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Provider'),
                  items: [
                    for (final provider in _providers)
                      DropdownMenuItem(
                        value: provider.id,
                        child: Text(provider.name),
                      ),
                  ],
                  onChanged: _busy || _providers.isEmpty
                      ? null
                      : (value) {
                          setState(() {
                            _provider = value!;
                            _key.clear();
                            _model.clear();
                            _modelPickerRevision++;
                            _modelNotice = null;
                            _models = const [];
                            _modelsSource = '';
                          });
                          unawaited(_discoverModels());
                        },
                ),
                if (_providers.isEmpty && _error == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
                const SizedBox(height: 20),
                if (_selectedProvider?.requiresApiKey != false)
                  TextFormField(
                    controller: _key,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'API key',
                      helperText: 'Kunci disimpan terenkripsi di server.',
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Masukkan API key.'
                        : null,
                    onFieldSubmitted: (_) => unawaited(_discoverModels()),
                  ),
                if (_selectedProvider?.requiresApiKey != false)
                  const SizedBox(height: 20),
                Autocomplete<String>(
                  key: ValueKey(_modelPickerRevision),
                  initialValue: TextEditingValue(text: _model.text),
                  optionsBuilder: (value) {
                    final query = value.text.trim().toLowerCase();
                    return _models
                        .where((model) => model.toLowerCase().contains(query))
                        .take(50);
                  },
                  onSelected: (value) => _model.text = value,
                  fieldViewBuilder:
                      (
                        context,
                        controller,
                        focusNode,
                        onFieldSubmitted,
                      ) => TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        enabled: !_busy,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Model AI',
                          helperText: _provider == 'opencode-free'
                              ? 'Pilih model dari katalog live terbaru.'
                              : _models.isEmpty
                              ? 'Masukkan ID model atau deteksi model yang tersedia.'
                              : 'Pilih dari ${_models.length} model atau isi ID secara manual.',
                        ),
                        onChanged: (value) => _model.text = value,
                        validator: (value) {
                          final model = (value ?? '').trim();
                          if (model.isEmpty) {
                            return 'Pilih atau masukkan ID model.';
                          }
                          if (_provider == 'opencode-free' &&
                              (_modelsSource != 'live' ||
                                  !_models.contains(model))) {
                            return 'Deteksi dan pilih model OpenCode Free dari daftar terbaru.';
                          }
                          return null;
                        },
                        onFieldSubmitted: (value) {
                          _model.text = value.trim();
                          onFieldSubmitted();
                        },
                      ),
                ),
                if (_models.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _modelsSource == 'live'
                          ? '${_models.length} model terdeteksi dari provider.'
                          : '${_models.length} model rekomendasi tersedia.',
                    ),
                  ),
                if (_modelNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _modelNotice!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _busy || _discoveringModels
                        ? null
                        : () => unawaited(_discoverModels()),
                    icon: _discoveringModels
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(
                      _discoveringModels
                          ? 'Mendeteksi model…'
                          : 'Deteksi model',
                    ),
                  ),
                ),
                if (_error != null) ProductError(_error!),
                const SizedBox(height: 28),
                FilledButton(
                  style: productButtonStyle,
                  onPressed: _busy || _providers.isEmpty ? null : _save,
                  child: Text(_busy ? 'Menyimpan…' : 'Simpan provider'),
                ),
              ],
            ),
          ),
          if (widget.onboarding)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                style: productButtonStyle,
                onPressed: _busy ? null : widget.session.signOut,
                child: const Text('Keluar'),
              ),
            ),
        ],
      ),
    ),
  );
}
