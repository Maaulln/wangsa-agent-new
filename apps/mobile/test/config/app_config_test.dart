import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/config/app_config.dart';

void main() {
  group('AppConfig.fromJson', () {
    test('membaca ketiga nilai dari berkas konfigurasi', () {
      final config = AppConfig.fromJson({
        'apiBaseUrl': 'https://api.wangsa.test',
        'defaultAgentId': '8f3a0000-0000-4000-8000-000000000001',
        'wakeWord': 'porcupine',
      });

      expect(config.apiBaseUrl, 'https://api.wangsa.test');
      expect(config.defaultAgentId, '8f3a0000-0000-4000-8000-000000000001');
      expect(config.wakeWord, 'porcupine');
    });

    test('membuang garis miring di akhir alamat API', () {
      final config = AppConfig.fromJson({
        'apiBaseUrl': 'https://api.wangsa.test/',
        'defaultAgentId': 'a',
      });

      expect(config.apiBaseUrl, 'https://api.wangsa.test');
    });

    test('memakai kata pemicu bawaan bila tidak disebut', () {
      final config = AppConfig.fromJson({
        'apiBaseUrl': 'https://api.wangsa.test',
        'defaultAgentId': 'a',
      });

      expect(config.wakeWord, AppConfig.defaultWakeWord);
    });

    test('menolak konfigurasi tanpa alamat API', () {
      expect(
        () => AppConfig.fromJson({'defaultAgentId': 'a'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('menolak alamat API kosong', () {
      expect(
        () => AppConfig.fromJson({'apiBaseUrl': '   ', 'defaultAgentId': 'a'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('membaca AccessKey wake word bila ada', () {
      final config = AppConfig.fromJson({
        'apiBaseUrl': 'https://api.wangsa.test',
        'defaultAgentId': 'a',
        'wakeWordAccessKey': 'kunci-picovoice',
      });

      expect(config.wakeWordAccessKey, 'kunci-picovoice');
    });

    test('AccessKey wake word null bila tidak disebut, bukan bawaan apa pun', () {
      final config = AppConfig.fromJson({
        'apiBaseUrl': 'https://api.wangsa.test',
        'defaultAgentId': 'a',
      });

      expect(config.wakeWordAccessKey, isNull);
    });

    test('AccessKey wake word kosong diperlakukan sama seperti tidak ada', () {
      final config = AppConfig.fromJson({
        'apiBaseUrl': 'https://api.wangsa.test',
        'defaultAgentId': 'a',
        'wakeWordAccessKey': '   ',
      });

      expect(config.wakeWordAccessKey, isNull);
    });
  });
}
