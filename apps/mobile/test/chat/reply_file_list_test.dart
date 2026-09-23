import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/api/models.dart';
import 'package:wangsa_mobile/chat/view/widgets/reply_file_list.dart';

void main() {
  group('ReplyFileList', () {
    testWidgets('tidak merender apa pun bila daftar berkas kosong', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ReplyFileList(files: [])),
        ),
      );

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byIcon(Icons.description_outlined), findsNothing);
    });

    testWidgets('dokumen tampil sebagai kartu dengan nama berkas dan tombol bagikan', (tester) async {
      final files = [
        ReplyFile(
          bytes: Uint8List.fromList([1, 2, 3]),
          filename: 'laporan.pdf',
          mimeType: 'application/pdf',
          kind: 'document',
          caption: 'Laporan QA',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReplyFileList(files: files)),
        ),
      );

      expect(find.text('laporan.pdf'), findsOneWidget);
      expect(find.text('Laporan QA'), findsOneWidget);
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    });

    testWidgets('dokumen tanpa bytes tampil dengan lambang rusak, tanpa tombol bagikan', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReplyFileList(files: [ReplyFile(filename: 'rusak.pdf')]),
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsNothing);
    });

    testWidgets('audio tampil sebagai kartu pemutar dengan tombol putar', (tester) async {
      final files = [
        ReplyFile(
          bytes: Uint8List.fromList([1, 2, 3]),
          filename: 'balasan.mp3',
          mimeType: 'audio/mpeg',
          kind: 'audio',
          caption: 'Balasan suara QA',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReplyFileList(files: files)),
        ),
      );

      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      expect(find.text('Balasan suara QA'), findsOneWidget);
    });

    testWidgets('audio tanpa bytes menonaktifkan tombol putar', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReplyFileList(
              files: [ReplyFile(kind: 'audio', filename: 'rusak.mp3')],
            ),
          ),
        ),
      );

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });
}
