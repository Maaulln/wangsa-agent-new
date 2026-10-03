import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/chat/view/chat_icons.dart';
import 'package:wangsa_mobile/api/models.dart';
import 'package:wangsa_mobile/chat/view/widgets/reply_image_gallery.dart';

void main() {
  group('ReplyImageGallery', () {
    testWidgets('tidak merender apa pun bila daftar gambar kosong', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ReplyImageGallery(images: [])),
        ),
      );

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byType(GestureDetector), findsNothing);
    });

    testWidgets('merender satu pratinjau per gambar', (tester) async {
      final images = [
        ReplyImage(bytes: Uint8List.fromList([1, 2, 3]), filename: 'a.png'),
        const ReplyImage(url: 'https://example.com/b.png'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReplyImageGallery(images: images)),
        ),
      );

      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets(
      'gambar tanpa bytes maupun url tampil sebagai lambang rusak dan tidak bisa diketuk',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: ReplyImageGallery(images: [ReplyImage()])),
          ),
        );

        expect(find.byIcon(ChatIcons.brokenImage), findsOneWidget);
        expect(find.byType(Image), findsNothing);

        await tester.tap(find.byIcon(ChatIcons.brokenImage));
        await tester.pumpAndSettle();

        // Tidak ada layar pratinjau yang terbuka — tidak ada rute baru.
        expect(find.byType(InteractiveViewer), findsNothing);
      },
    );

    testWidgets(
      'mengetuk pratinjau membuka layar penuh dengan pencet-cubit dan keterangan',
      (tester) async {
        final images = [
          ReplyImage(
            bytes: Uint8List.fromList([1, 2, 3]),
            filename: 'a.png',
            caption: 'sebuah keterangan',
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ReplyImageGallery(images: images)),
          ),
        );

        await tester.tap(find.byType(Image));
        await tester.pumpAndSettle();

        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.text('sebuah keterangan'), findsOneWidget);

        // Ketuk area kosong di luar gambar menutup layar pratinjau lagi.
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
      },
    );
  });
}
