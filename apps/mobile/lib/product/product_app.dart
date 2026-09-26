import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../llm/llm_settings_controller.dart';
import 'product_api.dart';
import 'product_auth_page.dart';
import 'product_session.dart';
import 'product_shell.dart';
import 'product_widgets.dart';

/// Mounted as MaterialApp.home so the existing Wangsa theme remains authority.
class ProductApp extends StatefulWidget {
  final String apiBaseUrl;
  final http.Client? httpClient;
  final KeyVault? vault;
  final Duration pollInterval;
  const ProductApp({
    super.key,
    required this.apiBaseUrl,
    this.httpClient,
    this.vault,
    this.pollInterval = const Duration(seconds: 5),
  });
  @override
  State<ProductApp> createState() => _ProductAppState();
}

class _ProductAppState extends State<ProductApp> {
  ProductSession? _session;
  String? _configError;
  @override
  void initState() {
    super.initState();
    try {
      _session = ProductSession(
        api: ProductApi(
          baseUrl: widget.apiBaseUrl,
          httpClient: widget.httpClient,
        ),
        vault: widget.vault ?? SecureKeyVault(),
      );
      _session!.restore();
    } on ProductApiException catch (error) {
      _configError = error.message;
    }
  }

  @override
  void dispose() {
    _session?.api.close();
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Wangsa')),
        body: ProductBody(
          children: [
            ProductError(_configError ?? 'Alamat server belum tersedia.'),
          ],
        ),
      );
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (session.restoring) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (session.restoreError != null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Wangsa')),
            body: ProductBody(
              children: [
                Text(
                  'Sambungkan kembali',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                ProductError(session.restoreError!, onRetry: session.restore),
                TextButton(
                  style: productButtonStyle,
                  onPressed: session.clear,
                  child: const Text('Masuk dengan akun lain'),
                ),
              ],
            ),
          );
        }
        if (session.user == null) return ProductAuthPage(session: session);
        // This navigator owns every authenticated route. A changed account removes
        // its entire stack immediately, including pending detail/form screens.
        return Navigator(
          key: ValueKey('${session.api.baseUrl}:${session.user!.id}'),
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ProductShell(
              session: session,
              pollInterval: widget.pollInterval,
            ),
          ),
        );
      },
    );
  }
}
