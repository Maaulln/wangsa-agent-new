import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../api/api_endpoints.dart';
import '../../api/api_result.dart';
import '../../api/models.dart';
import '../../api/wangsa_api_client.dart';
import '../mobile_auth_controller.dart';

/// Palet gelap khusus layar ini, meniru referensi desain "Log in or
/// sign up" ala ChatGPT (bottom-sheet dark modal) — sengaja lokal, tidak
/// menyentuh `WangsaTheme` global (sama keputusan yang dipakai di
/// ChatPage untuk `_ChatDark`).
abstract final class _AuthDark {
  static const bg = Color(0xFF000000);
  static const card = Color(0xFF1C1C1E);
  static const border = Color(0xFF3A3A3C);
  static const hint = Color(0xFF8E8E93);
}

/// Layar pendaftaran/masuk terbuka: siapa saja bisa daftar dengan
/// username + kata sandi, tampil sebagai kartu gelap penuh layar
/// (referensi Figma "Log in or sign up") dengan logo Wangsa — tidak lagi
/// meminta alamat server (dipakai diam-diam dari [initialApiUrl], bisa
/// diganti belakangan dari Pengaturan bila memang perlu).
///
/// Baris "Continue with Google/Apple/phone" adalah placeholder visual
/// murni (belum ada backend OAuth) — mengetuknya hanya menampilkan
/// pemberitahuan "segera hadir"; satu-satunya jalur yang benar-benar
/// jalan adalah username + kata sandi.
///
/// Alur daftar: isi username + kata sandi → `POST /api/v1/auth/signup` →
/// simpan token + profile → callback `onSignedIn`.
/// Alur masuk: username + kata sandi yang sama → `POST /api/v1/auth/login`.
///
/// [initialApiUrl] bisa basi (mis. IP Wi-Fi laptop yang tersimpan dari
/// sesi lama, sudah tidak terjangkau lagi lewat USB) — sebelum menyerah
/// dengan galat generik, [_submit] mencoba [apiCandidates] satu per satu
/// (localhost via `adb reverse`, `10.0.2.2` di emulator, dst., lihat
/// `buildApiCandidates`) dan melaporkan URL yang benar-benar hidup lewat
/// `onSignedIn(apiUrl: ...)`, supaya AuthGate menyimpannya dan pengguna
/// tidak mengalami masalah yang sama di percobaan berikutnya.
class SignupPage extends StatefulWidget {
  final WangsaApiClient apiClient;
  final MobileAuthController auth;
  final String initialApiUrl;
  final List<String> apiCandidates;
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
    this.apiCandidates = const [],
    required this.onSignedIn,
  });

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();

  /// false = daftar (akun baru), true = masuk (akun lama).
  bool _loginMode = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validateUsername() {
    final name = _nameController.text.trim().toLowerCase();
    if (name.length < 3 ||
        name.length > 32 ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(name)) {
      return 'Username 3-32 huruf kecil, angka, - atau _.';
    }
    return null;
  }

  String? _validatePassword() {
    final password = _passwordController.text;
    if (password.length < 8 || password.length > 128) {
      return 'Kata sandi 8-128 karakter.';
    }
    return null;
  }

  Future<({ApiResult<SignupResult> result, String url})> _attempt(
    String url,
    String name,
    String password,
  ) async {
    widget.apiClient.updateBaseUrl(url);
    final res = _loginMode
        ? await widget.apiClient.login(name, password)
        : await widget.apiClient.signup(name, password);
    return (result: res, url: url);
  }

  Future<void> _submit() async {
    final usernameError = _validateUsername();
    if (usernameError != null) {
      setState(() => _error = usernameError);
      return;
    }
    final passwordError = _validatePassword();
    if (passwordError != null) {
      setState(() => _error = passwordError);
      return;
    }
    final name = _nameController.text.trim().toLowerCase();
    final password = _passwordController.text;
    setState(() {
      _busy = true;
      _error = null;
    });

    var attempt = await _attempt(widget.initialApiUrl, name, password);
    // URL utama mati total (RUNTIME_ERROR: jaringan/timeout/host tak
    // dikenal) — coba kandidat lain sebelum menyerah, sama seperti
    // ChatBloc melakukannya pasca-login (lihat api_endpoints.dart).
    if (attempt.result.errorOrNull?.code == 'RUNTIME_ERROR') {
      for (final candidate in widget.apiCandidates) {
        if (candidate == widget.initialApiUrl) continue;
        final next = await _attempt(candidate, name, password);
        if (next.result.errorOrNull?.code != 'RUNTIME_ERROR') {
          attempt = next;
          break;
        }
      }
    }
    if (!mounted) return;

    final res = attempt.result;
    final resolvedUrl = attempt.url;
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
        apiUrl: resolvedUrl,
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
        'UNAUTHORIZED' => 'Username atau kata sandi tidak sesuai.',
        'RATE_LIMITED' =>
          'Terlalu banyak percobaan. Tunggu sejam lalu coba lagi.',
        _ => err?.message ?? diagnoseConnectionHint(resolvedUrl),
      };
    });
  }

  void _comingSoon(String label) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$label segera hadir.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _AuthDark.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              SvgPicture.asset(
                'assets/logo.svg',
                width: 56,
                height: 56,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
                semanticsLabel: 'Wangsa',
              ),
              const SizedBox(height: 20),
              Text(
                _loginMode ? 'Selamat datang kembali' : 'Daftar ke Wangsa',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _loginMode
                    ? 'Masuk dengan username dan kata sandi akunmu.'
                    : 'Satu username = satu profile + satu bot terisolasi.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _AuthDark.hint, fontSize: 14),
              ),
              const SizedBox(height: 28),
              _darkField(
                controller: _nameController,
                hint: 'Username',
                obscure: false,
              ),
              const SizedBox(height: 12),
              _darkField(
                controller: _passwordController,
                hint: 'Kata sandi',
                obscure: _obscurePassword,
                suffix: IconButton(
                  tooltip: _obscurePassword
                      ? 'Tampilkan kata sandi'
                      : 'Sembunyikan kata sandi',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: _AuthDark.hint,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFF453A), fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: const StadiumBorder(),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : Text(
                          _loginMode ? 'Masuk' : 'Daftar',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: Divider(color: _AuthDark.border)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'ATAU',
                      style: TextStyle(
                        color: _AuthDark.hint,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: _AuthDark.border)),
                ],
              ),
              const SizedBox(height: 20),
              _socialButton(
                icon: Icons.g_mobiledata_rounded,
                label: 'Lanjut dengan Google',
                background: Colors.transparent,
                border: _AuthDark.border,
                foreground: Colors.white,
                onTap: () => _comingSoon('Login Google'),
              ),
              const SizedBox(height: 10),
              _socialButton(
                icon: Icons.apple_rounded,
                label: 'Lanjut dengan Apple',
                background: Colors.black,
                border: _AuthDark.border,
                foreground: Colors.white,
                onTap: () => _comingSoon('Login Apple'),
              ),
              const SizedBox(height: 10),
              _socialButton(
                icon: Icons.phone_outlined,
                label: 'Lanjut dengan nomor HP',
                background: Colors.transparent,
                border: _AuthDark.border,
                foreground: Colors.white,
                onTap: () => _comingSoon('Login nomor HP'),
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _loginMode = !_loginMode;
                        _error = null;
                      }),
                child: Text(
                  _loginMode
                      ? 'Belum punya akun? Daftar'
                      : 'Sudah punya akun? Masuk',
                  style: const TextStyle(color: _AuthDark.hint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _darkField({
    required TextEditingController controller,
    required String hint,
    required bool obscure,
    Widget? suffix,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      enabled: !_busy,
      obscureText: obscure,
      autocorrect: false,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _AuthDark.hint),
        filled: true,
        fillColor: _AuthDark.card,
        suffixIcon: suffix,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _AuthDark.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _AuthDark.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.white54),
        ),
      ),
    );
  }

  Widget _socialButton({
    required IconData icon,
    required String label,
    required Color background,
    required Color border,
    required Color foreground,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, color: foreground, size: 20),
        label: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: background,
          side: BorderSide(color: border),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}
