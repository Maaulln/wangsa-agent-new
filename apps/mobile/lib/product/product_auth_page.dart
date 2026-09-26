import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'product_api.dart';
import 'product_session.dart';
import 'product_widgets.dart';

class ProductAuthPage extends StatefulWidget {
  final ProductSession session;
  const ProductAuthPage({super.key, required this.session});
  @override
  State<ProductAuthPage> createState() => _ProductAuthPageState();
}

class _ProductAuthPageState extends State<ProductAuthPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  bool _signup = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.authenticate(
        _signup ? 'signup' : 'login',
        _name.text.trim().toLowerCase(),
        _password.text,
      );
    } on ProductApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.isUnauthorized
              ? 'Username atau kata sandi belum sesuai.'
              : error.message,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Akun belum bisa disimpan. Coba lagi.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Wangsa')),
    body: SafeArea(
      child: ProductBody(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SvgPicture.asset(
              'assets/logo.svg',
              width: 56,
              height: 56,
              colorFilter: ColorFilter.mode(
                Theme.of(context).colorScheme.primary,
                BlendMode.srcIn,
              ),
              semanticsLabel: 'Wangsa',
            ),
          ),
          const SizedBox(height: 28),
          Text(
            _signup ? 'Mulai dari kebutuhanmu.' : 'Selamat datang kembali.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Ceritakan pekerjaanmu. Wangsa membantu menyelesaikannya dan menyimpan langkah yang bisa dipakai lagi.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 32),
          AutofillGroup(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _name,
                    enabled: !_busy,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      helperText: '3–32 huruf kecil, angka, tanda - atau _',
                    ),
                    validator: (value) =>
                        RegExp(
                          r'^[a-z0-9][a-z0-9_-]{2,31}$',
                        ).hasMatch((value ?? '').trim().toLowerCase())
                        ? null
                        : 'Masukkan username yang valid.',
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    autofillHints: [
                      _signup
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Kata sandi',
                      helperText: _signup ? 'Minimal 10 karakter.' : null,
                      suffixIcon: IconButton(
                        tooltip: _obscure
                            ? 'Tampilkan kata sandi'
                            : 'Sembunyikan kata sandi',
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (value) =>
                        (value ?? '').length >= (_signup ? 10 : 1)
                        ? null
                        : 'Kata sandi minimal 10 karakter.',
                  ),
                  if (_error != null) ProductError(_error!),
                  const SizedBox(height: 24),
                  FilledButton(
                    style: productButtonStyle,
                    onPressed: _busy ? null : _submit,
                    child: Text(
                      _busy
                          ? 'Menghubungkan…'
                          : _signup
                          ? 'Buat akun'
                          : 'Masuk',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    style: productButtonStyle,
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _signup = !_signup;
                            _error = null;
                          }),
                    child: Text(
                      _signup
                          ? 'Sudah punya akun? Masuk'
                          : 'Belum punya akun? Daftar',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
