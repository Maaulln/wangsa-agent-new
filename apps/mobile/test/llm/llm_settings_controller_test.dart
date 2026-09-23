import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/llm/llm_override.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';

void main() {
  group('LlmSettingsController', () {
    test('awal null (bawaan Gemma) tanpa simpanan', () {
      final controller = LlmSettingsController.fake();
      expect(controller.value, isNull);
      expect(controller.isCustom, isFalse);
    });

    test('saveCustom menyimpan dan mengembalikan override', () async {
      final controller = LlmSettingsController.fake();

      final error = await controller.saveCustom(
        baseURL: 'https://api.openai.com/v1',
        apiKey: 'sk-uji',
        model: 'gpt-4o-mini',
      );

      expect(error, isNull);
      expect(
        controller.value,
        const LlmOverride(baseURL: 'https://api.openai.com/v1', apiKey: 'sk-uji', model: 'gpt-4o-mini'),
      );
      expect(controller.isCustom, isTrue);
    });

    test('saveCustom menolak kolom kosong dan skema bukan http(s)', () async {
      final controller = LlmSettingsController.fake();

      expect(await controller.saveCustom(baseURL: '', apiKey: 'k', model: 'm'), isNotNull);
      expect(await controller.saveCustom(baseURL: 'ftp://x.test', apiKey: 'k', model: 'm'), isNotNull);
      expect(controller.value, isNull);
    });

    test('useDefault menghapus kunci dan kembali null', () async {
      final vault = _ExposedVault();
      final controller = LlmSettingsController.fake(vault: vault);
      await controller.saveCustom(baseURL: 'https://api.openai.com/v1', apiKey: 'sk-uji', model: 'm');
      expect(vault.store, isNotEmpty);

      await controller.useDefault();

      expect(controller.value, isNull);
      expect(vault.store, isEmpty);
    });
  });
}

class _ExposedVault implements KeyVault {
  final Map<String, String> store = {};
  @override
  Future<String?> read(String key) async => store[key];
  @override
  Future<void> write(String key, String value) async => store[key] = value;
  @override
  Future<void> delete(String key) async => store.remove(key);
}
