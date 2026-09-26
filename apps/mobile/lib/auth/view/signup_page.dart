import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/wangsa_api_client.dart';
import '../mobile_auth_controller.dart';

/// Layar pendaftaran terbuka: siapa saja bisa daftar.
///
/// Alur: isi alamat server + username → `POST /api/v1/auth/signup` →
/// simpan token + profile → callback `onSignedIn`. Pengguna lama yang
/// sudah punya token bisa lewat mode "punya token" tanpa daftar ulang.
class SignupPage extends StatefulWidget {
  final WangsaApiClient apiClient;
  final MobileAuthController auth;
  final String initialApiUrl;
  final Future<void> Function({
    required String token,
    required String profile,
    required String apiUrl,
  })
  onSignedIn;

  const SignupPage({
    super.key,
    required this.apiClient,
    required this.auth,
    required this.initialApiUrl,
    required this.onSignedIn,
  });

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _nameController;
  late final TextEditingController _tokenController;
  bool _useTokenMode = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialApiUrl);
    _nameController = TextEditingController();
    _tokenController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  String _normalizedUrl(String v) {
    var r = v.trim();
    while (r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }

  Future<void> _applyUrl(String url) async {
    widget.apiClient.updateBaseUrl(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wangsa_chat_api_url', url);
  }

  Future<void> _doSignup() async {
    final url = _normalizedUrl(_urlController.text);
    final name = _nameController.text.trim().toLowerCase();
    if (url.isEmpty) {
      setState(() => _error = 'Alamat server tidak boleh kosong.');
      return;
    }
    if (name.length < 3 ||
        name.length > 32 ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(name)) {
      setState(() => _error = 'Username 3-32 huruf kecil, angka, - atau _.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _applyUrl(url);
    final res = await widget.apiClient.signup(name);
    if (!mounted) return;
    if (res.isSuccess && res.dataOrNull != null) {
      final data = res.dataOrNull!;
      if (data.token.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'Server tidak mengembalikan token. Coba lagi.';
        });
        return;
      }
      widget.apiClient.updateToken(data.token);
      await widget.auth.saveSession(token: data.token, profile: data.profile);
      // saveSession memicu rebuild AuthGate (notifyListeners) yang bisa
      // membuang layar ini — jangan sentuh state sesudahnya tanpa cek.
      await widget.onSignedIn(
        token: data.token,
        profile: data.profile,
        apiUrl: url,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }
    final err = res.errorOrNull;
    setState(() {
      _busy = false;
      _error = switch (err?.code) {
        'CONFLICT' => 'Username sudah dipakai. Pilih nama lain.',
        'RATE_LIMITED' =>
          'Terlalu banyak pendaftaran. Tunggu sejam lalu coba lagi.',
        _ => err?.message ?? 'Pendaftaran gagal. Periksa alamat server.',
      };
    });
  }

  Future<void> _doUseToken() async {
    final url = _normalizedUrl(_urlController.text);
    final token = _tokenController.text.trim();
    if (url.isEmpty || token.isEmpty) {
      setState(() => _error = 'Alamat server dan token wajib diisi.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _applyUrl(url);
    widget.apiClient.updateToken(token);
    final me = await widget.apiClient.getMe();
    if (!mounted) return;
    if (me.isSuccess && me.dataOrNull != null) {
      await widget.auth.saveSession(
        token: token,
        profile: me.dataOrNull!.profile,
      );
      await widget.onSignedIn(
        token: token,
        profile: me.dataOrNull!.profile,
        apiUrl: url,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }
    widget.apiClient.updateToken(null);
    final err = me.errorOrNull;
    setState(() {
      _busy = false;
      _error = err?.message ?? 'Token tidak valid.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daftar ke Wangsa')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              _useTokenMode ? 'Masuk dengan token' : 'Buat akun baru',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _useTokenMode
                  ? 'Tempel token yang pernah diberikan server. Token menentukan profile milikmu.'
                  : 'Satu username = satu profile + satu bot terisolasi. Setelah daftar, hubungkan LLM milikmu.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _urlController,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Alamat server',
                hintText: 'http://localhost:9901',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_useTokenMode)
              TextField(
                controller: _tokenController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Token',
                  border: OutlineInputBorder(),
                ),
              )
            else
              TextField(
                controller: _nameController,
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  hintText: 'mis. budi21',
                  helperText: '3-32 huruf kecil, angka, - atau _',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _doSignup(),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy
                  ? null
                  : (_useTokenMode ? _doUseToken : _doSignup),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_useTokenMode ? 'Masuk' : 'Daftar'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _useTokenMode = !_useTokenMode;
                      _error = null;
                    }),
              child: Text(
                _useTokenMode
                    ? 'Belum punya akun? Daftar'
                    : 'Sudah punya token? Masuk',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
