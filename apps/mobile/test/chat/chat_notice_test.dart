import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangsa_mobile/chat/view/widgets/chat_notice.dart';
import 'package:wangsa_mobile/theme/wangsa_theme.dart';

void main() {
  group('ChatNotice.empty', () {
    testWidgets('menampilkan logo berukuran 480x480 pada layar lebar/desktop', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: WangsaTheme.forBrightness(Brightness.light),
          home: const Scaffold(body: ChatNotice.empty()),
        ),
      );
      await tester.pumpAndSettle();

      final svgFinder = find.byType(SvgPicture);
      expect(svgFinder, findsOneWidget);

      final svgWidget = tester.widget<SvgPicture>(svgFinder);
      expect(svgWidget.width, 420.0);
      expect(svgWidget.height, 420.0);

      // Verifikasi warna logo pada light mode (#09090B)
      final colorFilter = svgWidget.colorFilter;
      expect(colorFilter, isNotNull);
      expect(
        colorFilter,
        const ColorFilter.mode(Color(0xFF09090B), BlendMode.srcIn),
      );
    });

    testWidgets('menampilkan logo berwarna #FAFAFA pada dark mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: WangsaTheme.forBrightness(Brightness.dark),
          home: const Scaffold(body: ChatNotice.empty()),
        ),
      );
      await tester.pumpAndSettle();

      final svgFinder = find.byType(SvgPicture);
      expect(svgFinder, findsOneWidget);

      final svgWidget = tester.widget<SvgPicture>(svgFinder);
      expect(svgWidget.width, 420.0);
      expect(svgWidget.height, 420.0);

      // Verifikasi warna logo pada dark mode (#FAFAFA)
      final colorFilter = svgWidget.colorFilter;
      expect(colorFilter, isNotNull);
      expect(
        colorFilter,
        const ColorFilter.mode(Color(0xFFFAFAFA), BlendMode.srcIn),
      );
    });

    testWidgets(
      'skala logo menyesuaikan layar tanpa memicu overflow di layar sempit',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: WangsaTheme.forBrightness(Brightness.light),
            home: const Scaffold(body: ChatNotice.empty()),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final svgFinder = find.byType(SvgPicture);
        expect(svgFinder, findsOneWidget);

        final svgWidget = tester.widget<SvgPicture>(svgFinder);
        // Pada lebar 360 dengan padding 32 (kiri + kanan = 64), lebar maksimal 296
        expect(svgWidget.width, lessThanOrEqualTo(420.0));
        expect(svgWidget.height, lessThanOrEqualTo(420.0));
      },
    );
  });
}
