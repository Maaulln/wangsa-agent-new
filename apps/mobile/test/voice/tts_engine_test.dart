import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/voice/tts_engine.dart';

void main() {
  group('speechText', () {
    test('menghapus penebal, miring, dan judul', () {
      expect(speechText('# Halo\n\nIni **penting** dan _miring_.'), 'Halo Ini penting dan miring.');
    });

    test('tautan Markdown menjadi teksnya saja dan URL mentah menjadi "tautan"', () {
      expect(
        speechText('Buka [situs resmi](https://contoh.id/x) atau https://contoh.id/y sekarang'),
        'Buka situs resmi atau tautan sekarang',
      );
    });

    test('blok kode dibuang dan kode satu baris dibacakan tanpa backtick', () {
      expect(speechText('Jalankan `bun test`:\n```\nbun test\n```\nselesai'), 'Jalankan bun test: selesai');
    });

    test('butir daftar kehilangan penandanya', () {
      expect(speechText('- satu\n- dua\n1. tiga'), 'satu dua tiga');
    });

    test('garis bawah di tengah kata tidak dihapus', () {
      expect(speechText('model hallo_wangsa siap'), 'model hallo_wangsa siap');
    });

    test('teks kosong atau hanya tanda menghasilkan string kosong', () {
      expect(speechText('   '), '');
      expect(speechText('```\nkode saja\n```'), '');
    });
  });
}
