import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../llm/llm_settings_controller.dart';
import 'product_api.dart';
import 'product_models.dart';

String newRequestKey() => List.generate(
  24,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class ProductSession extends ChangeNotifier {
  final ProductApi api;
  final KeyVault vault;
  ProductUser? user;
  ProductProvider? provider;
  bool restoring = true;
  String? restoreError;
  int _generation = 0;
  bool _disposed = false;
  bool _signingOut = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  ProductSession({required this.api, required this.vault});
  String get tokenKey =>
      'wangsa_product_${base64Url.encode(utf8.encode(api.baseUrl))}_token';
  String get _pendingKey => '${tokenKey}_${user!.id}_pending';

  Future<void> restore() async {
    final generation = ++_generation;
    restoring = true;
    restoreError = null;
    notifyListeners();
    try {
      final token = await vault.read(tokenKey);
      if (_disposed || generation != _generation) return;
      api.token = token;
      if (api.token != null) {
        final restoredUser = await api.me();
        if (_disposed || generation != _generation) return;
        final restoredProvider = await api.provider();
        if (_disposed || generation != _generation) return;
        user = restoredUser;
        provider = restoredProvider;
      }
    } on ProductApiException catch (error) {
      if (_disposed || generation != _generation) return;
      if (error.isUnauthorized) {
        await clear();
      } else {
        restoreError = error.message;
      }
    } catch (_) {
      if (generation == _generation) {
        restoreError = 'Sesi belum bisa dibuka. Coba lagi.';
      }
    } finally {
      if (generation == _generation) {
        restoring = false;
        notifyListeners();
      }
    }
  }

  Future<void> authenticate(
    String action,
    String username,
    String password,
  ) async {
    final auth = await api.authenticate(action, username, password);
    await vault.write(tokenKey, auth.token);
    api.token = auth.token;
    user = auth.user;
    provider = null;
    restoreError = null;
    _generation++;
    notifyListeners();
    await refreshProvider();
  }

  Future<T> run<T>(Future<T> Function() action) async {
    final generation = _generation;
    try {
      final result = await action();
      if (generation != _generation) {
        throw const ProductApiException(
          'SESSION_CHANGED',
          'Akun telah berubah.',
        );
      }
      return result;
    } on ProductApiException catch (error) {
      if (error.isUnauthorized && generation == _generation) await clear();
      rethrow;
    }
  }

  Future<void> refreshProvider() async {
    provider = await run(api.provider);
    notifyListeners();
  }

  Future<void> signOut() async {
    if (_signingOut) return;
    _signingOut = true;
    // Start revocation with the old bearer, but local logout never waits on
    // a network timeout. Consume its error even when secure storage fails.
    final revoke = api.logout().catchError((_) {});
    try {
      await clear();
      await revoke;
    } finally {
      _signingOut = false;
    }
  }

  Future<void> clear() async {
    _generation++;
    final pendingKey = user == null ? null : _pendingKey;
    user = null;
    provider = null;
    api.token = null;
    restoreError = null;
    restoring = false;
    try {
      await vault.delete(tokenKey);
      if (pendingKey != null) await vault.delete(pendingKey);
    } finally {
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> pending() async {
    if (user == null) return null;
    final value = await vault.read(_pendingKey);
    if (value == null) return null;
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> savePending(Map<String, dynamic> value) =>
      vault.write(_pendingKey, jsonEncode(value));
  Future<void> clearPending() async {
    if (user != null) await vault.delete(_pendingKey);
  }

  Future<Map<String, dynamic>?> pendingReply(String jobId) async {
    if (user == null) return null;
    final value = await vault.read('${_pendingKey}_reply_$jobId');
    if (value == null) return null;
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> savePendingReply(String jobId, Map<String, dynamic> value) =>
      vault.write('${_pendingKey}_reply_$jobId', jsonEncode(value));
  Future<void> clearPendingReply(String jobId) async {
    if (user != null) await vault.delete('${_pendingKey}_reply_$jobId');
  }
}
