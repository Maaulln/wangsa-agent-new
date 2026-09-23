import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/voice/wake_word_engine.dart';

void main() {
  group('SherpaOnnxWakeWordEngine', () {
    test('createSherpaOnnxEngine memenuhi kontrak WakeWordEngineFactory', () {
      const WakeWordEngineFactory factory = createSherpaOnnxEngine;
      expect(factory, isNotNull);
    });

    test('konversi PCM16 bytes ke Float32List menghasilkan skala normal -1.0 sampai 1.0', () {
      // 0, max positive 32767, min negative -32768
      final bytes = Uint8List(6);
      final byteData = ByteData.sublistView(bytes);
      byteData.setInt16(0, 0, Endian.little);
      byteData.setInt16(2, 32767, Endian.little);
      byteData.setInt16(4, -32768, Endian.little);

      final samples = SherpaOnnxWakeWordEngine.convertBytesToFloat32ForTest(bytes);

      expect(samples.length, 3);
      expect(samples[0], closeTo(0.0, 0.0001));
      expect(samples[1], closeTo(1.0, 0.001));
      expect(samples[2], closeTo(-1.0, 0.001));
    });
  });
}
