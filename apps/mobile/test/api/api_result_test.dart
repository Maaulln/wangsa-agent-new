import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/api/api_result.dart';

void main() {
  group('ApiResult.fromEnvelope', () {
    test('membaca amplop sukses dan memanggil parser data', () {
      final result = ApiResult.fromEnvelope<String>({
        'success': true,
        'data': {'response': 'halo'},
      }, (data) => data['response'] as String);

      expect(result.isSuccess, isTrue);
      expect(result.dataOrNull, 'halo');
      expect(result.errorOrNull, isNull);
    });

    test('membaca amplop gagal beserta kodenya', () {
      final result = ApiResult.fromEnvelope<String>({
        'success': false,
        'error': {'code': 'NOT_FOUND', 'message': 'Not found.'},
      }, (data) => data['response'] as String);

      expect(result.isSuccess, isFalse);
      expect(result.errorOrNull?.code, 'NOT_FOUND');
      expect(result.errorOrNull?.message, 'Not found.');
    });

    test('amplop tanpa bentuk yang dikenal menjadi RUNTIME_ERROR', () {
      final result = ApiResult.fromEnvelope<String>({
        'tidak': 'dikenal',
      }, (data) => data['response'] as String);

      expect(result.isSuccess, isFalse);
      expect(result.errorOrNull?.code, 'RUNTIME_ERROR');
    });

    test(
      'data yang tidak sesuai bentuk tidak melempar, tetapi jadi RUNTIME_ERROR',
      () {
        final result = ApiResult.fromEnvelope<String>({
          'success': true,
          'data': 'bukan objek',
        }, (data) => data['response'] as String);

        expect(result.isSuccess, isFalse);
        expect(result.errorOrNull?.code, 'RUNTIME_ERROR');
      },
    );
  });
}
