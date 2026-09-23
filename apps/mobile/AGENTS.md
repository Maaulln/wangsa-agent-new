# Flutter & BLoC Development Guidelines

## Widget Testing & State Lifecycle Guardrails

1. **BLoC Lifecycle in Widget Tests (`addTearDown`)**:
   - Jangan pernah memanggil `await bloc.close()` di dalam badan `testWidgets` saat BLoC dipasang ke pohon widget melalui `BlocProvider.value`. Langganan aktif dari `BlocConsumer` atau `BlocBuilder` akan menyebabkan deadlock pada `bloc.close()`.
   - Selalu daftarkan pembersihan BLoC tepat setelah instansiasi menggunakan `addTearDown(bloc.close)`:
     ```dart
     final bloc = ChatBloc(...);
     addTearDown(bloc.close);
     ```

2. **Continuous Animations in Widget Tests**:
   - Hindari `await tester.pumpAndSettle()` ketika widget dengan animasi berulang (`AnimationController.repeat()`, denyut, indikator memuat tak tentu) sedang dirender; ini menyebabkan test mengalami *timeout* (10 menit).
   - Untuk menguji widget beranimasi:
     - Bungkus dengan `MediaQuery(data: const MediaQueryData(disableAnimations: true), child: ...)` untuk menguji perilaku tanpa gerak (*reduced-motion*).
     - Atau gunakan pemompaan frame bertahap: `await tester.pump()` atau `await tester.pump(const Duration(milliseconds: 100))`.

3. **Stream-Driven UI Updates in Tests**:
   - Mengirim event ke Stream Dart (`StreamController.add`) dijadwalkan secara asinkron dalam antrean *microtask*.
   - Pompa dua kali agar perubahan status dari *stream* ter-render di antarmuka:
     ```dart
     streamSource.emit(event);
     await tester.pump(); // Menjalankan microtask, menandai elemen kotor
     await tester.pump(); // Merekonsiliasi dan membangun ulang widget
     ```

4. **Disambiguating `find.text` in Forms & Composers**:
   - `find.text(...)` mencocokkan `Text` sekaligus `EditableText` (yang dirender secara internal oleh `TextField`).
   - Ketika teks dapat muncul pada input teks dan widget pratinjau/transkrip sekaligus, batasi lingkup pencarian:
     ```dart
     expect(
       find.descendant(of: find.byType(TargetWidget), matching: find.text('query')),
       findsOneWidget,
     );
     ```
