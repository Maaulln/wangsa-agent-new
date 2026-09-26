import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';
import 'package:wangsa_mobile/product/product_api.dart';
import 'package:wangsa_mobile/product/product_app.dart';
import 'package:wangsa_mobile/product/product_models.dart';
import 'package:wangsa_mobile/product/product_session.dart';
import 'package:wangsa_mobile/product/product_job_form.dart';
import 'package:wangsa_mobile/product/product_job_page.dart';
import 'package:wangsa_mobile/product/product_provider_page.dart';
import 'package:wangsa_mobile/product/product_shell.dart';
import 'package:wangsa_mobile/product/product_skill_page.dart';
import 'package:wangsa_mobile/theme/wangsa_theme.dart';

class Vault implements KeyVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

http.Response ok(Object? data, [int status = 200]) =>
    http.Response(jsonEncode({'data': data}), status);
final job = <String, dynamic>{
  'id': 'job-a',
  'title': 'Laporan mingguan',
  'prompt': 'Susun laporan dari bahan yang saya berikan.',
  'status': 'completed',
  'report': '## Hasil\nLaporan telah disusun dan diverifikasi.',
  'events': [
    {'message': 'Laporan siap dibaca.', 'created_at': '2026-09-25T03:00:00Z'},
  ],
  'updated_at': '2026-09-25T03:00:00Z',
};

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['WANGSA_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'model picker discovers keyless models and saves without an API key',
    (tester) async {
      Map<String, dynamic>? saved;
      final session =
          ProductSession(
              vault: Vault(),
              api: ProductApi(
                baseUrl: 'https://api.example',
                httpClient: MockClient((request) async {
                  if (request.url.path.endsWith('/provider/catalog')) {
                    return ok([
                      {
                        'id': 'opencode-free',
                        'name': 'OpenCode Free',
                        'requires_api_key': false,
                      },
                    ]);
                  }
                  if (request.url.path.endsWith('/provider/models')) {
                    return ok({
                      'models': ['free-model-one'],
                      'source': 'live',
                    });
                  }
                  if (request.method == 'PUT' &&
                      request.url.path.endsWith('/provider')) {
                    saved = jsonDecode(request.body) as Map<String, dynamic>;
                    return ok({});
                  }
                  if (request.url.path.endsWith('/provider')) {
                    return ok({
                      'configured': true,
                      'provider': 'opencode-free',
                      'model': 'free-model-one',
                    });
                  }
                  return ok({});
                }),
              ),
            )
            ..user = const ProductUser(id: 'alice', username: 'alice')
            ..provider = const ProductProvider(
              configured: true,
              provider: 'opencode-free',
              model: 'free-model-one',
            );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ProductProviderPage(session: session)),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 model terdeteksi dari provider.'), findsOneWidget);
      expect(find.text('API key'), findsNothing);
      await tester.tap(find.text('Simpan provider'));
      await tester.pumpAndSettle();
      expect(saved, {
        'provider': 'opencode-free',
        'model': 'free-model-one',
        'api_key': '',
      });
    },
  );
  testWidgets(
    'refreshing model discovery replaces options with the latest list',
    (tester) async {
      var discoveryCalls = 0;
      final session =
          ProductSession(
              vault: Vault(),
              api: ProductApi(
                baseUrl: 'https://api.example',
                httpClient: MockClient((request) async {
                  if (request.url.path.endsWith('/provider/catalog')) {
                    return ok([
                      {
                        'id': 'opencode-free',
                        'name': 'OpenCode Free',
                        'requires_api_key': false,
                      },
                    ]);
                  }
                  if (request.url.path.endsWith('/provider/models')) {
                    discoveryCalls++;
                    return ok({
                      'models': discoveryCalls == 1
                          ? ['stale-model']
                          : ['fresh-model-a', 'fresh-model-b'],
                      'source': 'live',
                    });
                  }
                  return ok({});
                }),
              ),
            )
            ..user = const ProductUser(id: 'alice', username: 'alice')
            ..provider = const ProductProvider(
              configured: true,
              provider: 'opencode-free',
              model: 'stale-model',
            );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(home: ProductProviderPage(session: session)),
      );
      await tester.pumpAndSettle();
      expect(discoveryCalls, 1);
      expect(find.text('1 model terdeteksi dari provider.'), findsOneWidget);

      await tester.tap(find.text('Deteksi model'));
      await tester.pumpAndSettle();
      expect(discoveryCalls, 2);
      expect(find.text('2 model terdeteksi dari provider.'), findsOneWidget);

      final modelField = find.descendant(
        of: find.byType(Autocomplete<String>),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(modelField, 'fresh-model');
      await tester.pumpAndSettle();
      expect(find.text('fresh-model-a'), findsOneWidget);
      expect(find.text('fresh-model-b'), findsOneWidget);
      expect(find.text('stale-model'), findsNothing);
    },
  );
  testWidgets('live OpenCode models invalidate a saved model that was delisted', (
    tester,
  ) async {
    var saveCalls = 0;
    final session =
        ProductSession(
            vault: Vault(),
            api: ProductApi(
              baseUrl: 'https://api.example',
              httpClient: MockClient((request) async {
                if (request.url.path.endsWith('/provider/catalog')) {
                  return ok([
                    {
                      'id': 'opencode-free',
                      'name': 'OpenCode Free',
                      'requires_api_key': false,
                    },
                  ]);
                }
                if (request.url.path.endsWith('/provider/models')) {
                  return ok({
                    'models': ['space-bunny-free'],
                    'source': 'live',
                  });
                }
                if (request.method == 'PUT' &&
                    request.url.path.endsWith('/provider')) {
                  saveCalls++;
                  return ok({});
                }
                return ok({
                  'configured': true,
                  'provider': 'opencode-free',
                  'model': 'hy3-free',
                });
              }),
            ),
          )
          ..user = const ProductUser(id: 'alice', username: 'alice')
          ..provider = const ProductProvider(
            configured: true,
            provider: 'opencode-free',
            model: 'hy3-free',
          );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ProductProviderPage(session: session)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Model hy3-free sudah tidak tersedia. Pilih model OpenCode Free dari daftar terbaru.',
      ),
      findsOneWidget,
    );
    expect(find.text('1 model terdeteksi dari provider.'), findsOneWidget);
    await tester.tap(find.text('Simpan provider'));
    await tester.pumpAndSettle();

    expect(saveCalls, 0);
    expect(find.text('Pilih atau masukkan ID model.'), findsOneWidget);
  });
  testWidgets('manual jobs refresh is queued behind an in-flight poll', (
    tester,
  ) async {
    final firstJobsResponse = Completer<http.Response>();
    var jobsCalls = 0;
    final updatedJob = {...job, 'id': 'job-b', 'title': 'Laporan terbaru'};
    final session =
        ProductSession(
            vault: Vault(),
            api: ProductApi(
              baseUrl: 'https://api.example',
              httpClient: MockClient((request) async {
                if (request.url.path.endsWith('/jobs')) {
                  jobsCalls++;
                  if (jobsCalls == 1) return firstJobsResponse.future;
                  return ok([job, updatedJob]);
                }
                if (request.url.path.endsWith('/skills')) return ok([]);
                return ok({});
              }),
            ),
          )
          ..user = const ProductUser(id: 'alice', username: 'alice')
          ..provider = const ProductProvider(
            configured: true,
            provider: 'openai',
            model: 'chosen-model',
          );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ProductShell(
          session: session,
          pollInterval: const Duration(minutes: 5),
        ),
      ),
    );
    await tester.pump();
    expect(jobsCalls, 1);

    await tester.tap(find.byTooltip('Perbarui'));
    await tester.pump();
    firstJobsResponse.complete(ok([job]));
    await tester.pumpAndSettle();

    expect(jobsCalls, 2);
    expect(find.text('Laporan terbaru'), findsOneWidget);
  });
  testWidgets('manual detail refresh is queued behind an in-flight poll', (
    tester,
  ) async {
    final firstJobResponse = Completer<http.Response>();
    var jobCalls = 0;
    final updated = {
      ...job,
      'report': '## Hasil terbaru\nData terbaru dari server.',
    };
    final session =
        ProductSession(
            vault: Vault(),
            api: ProductApi(
              baseUrl: 'https://api.example',
              httpClient: MockClient((request) async {
                if (request.url.path.endsWith('/jobs/job-a')) {
                  jobCalls++;
                  if (jobCalls == 1) return firstJobResponse.future;
                  return ok(updated);
                }
                return ok([]);
              }),
            ),
          )
          ..user = const ProductUser(id: 'alice', username: 'alice')
          ..provider = const ProductProvider(
            configured: true,
            provider: 'openai',
            model: 'chosen-model',
          );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ProductJobPage(
          session: session,
          jobId: 'job-a',
          pollInterval: const Duration(minutes: 5),
        ),
      ),
    );
    await tester.pump();
    expect(jobCalls, 1);

    await tester.tap(find.byTooltip('Perbarui'));
    await tester.pump();
    firstJobResponse.complete(ok(job));
    await tester.pumpAndSettle();

    expect(jobCalls, 2);
    expect(find.textContaining('Data terbaru dari server.'), findsOneWidget);
  });
  testWidgets(
    'failed job can be retried with its request but fresh credentials',
    (tester) async {
      final failedJob = {
        ...job,
        'status': 'failed',
        'error': 'Model provider ditolak.',
      };
      final session =
          ProductSession(
              vault: Vault(),
              api: ProductApi(
                baseUrl: 'https://api.example',
                httpClient: MockClient((request) async {
                  if (request.url.path.endsWith('/jobs/job-a')) {
                    return ok(failedJob);
                  }
                  return ok([]);
                }),
              ),
            )
            ..user = const ProductUser(id: 'alice', username: 'alice')
            ..provider = const ProductProvider(
              configured: true,
              provider: 'openai',
              model: 'chosen-model',
            );
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ProductJobPage(
            session: session,
            jobId: 'job-a',
            pollInterval: const Duration(minutes: 5),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Buat ulang pekerjaan'));
      await tester.tap(find.text('Buat ulang pekerjaan'));
      await tester.pumpAndSettle();

      final promptField = find.widgetWithText(TextField, 'Kebutuhanmu');
      expect(
        tester.widget<TextField>(promptField).controller!.text,
        job['prompt'],
      );
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'NetID situs (opsional)'),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Kata sandi situs (opsional)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final passwordField = find.widgetWithText(
        TextField,
        'Kata sandi situs (opsional)',
      );
      expect(tester.widget<TextField>(passwordField).controller!.text, isEmpty);
    },
  );
  setUpAll(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/Roboto-regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'API pins origin, refuses redirects, and sends idempotency key',
    () async {
      expect(
        () => ProductApi(baseUrl: 'http://example.com'),
        throwsA(isA<ProductApiException>()),
      );
      expect(
        () => ProductApi(baseUrl: 'https://user:password@example.com'),
        throwsA(isA<ProductApiException>()),
      );
      expect(
        () => ProductApi(
          baseUrl: 'http://localhost:9902',
          allowInsecureLocal: false,
        ),
        throwsA(isA<ProductApiException>()),
      );
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer private-token');
        expect(request.headers['Idempotency-Key'], 'same-request-key');
        expect(jsonDecode(request.body)['browser_secrets'], {
          'netid': 'student@example.edu',
          'password': 'private-site-password',
        });
        return ok(job, 202);
      });
      final api = ProductApi(
        baseUrl: 'https://api.example.com',
        httpClient: client,
      )..token = 'private-token';
      expect(
        (await api.createJob(
          'Report',
          'Input',
          'same-request-key',
          browserSecrets: {
            'netid': 'student@example.edu',
            'password': 'private-site-password',
          },
        )).id,
        'job-a',
      );
      final redirect = ProductApi(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'https://evil.example'},
          ),
        ),
      );
      await expectLater(
        redirect.me(),
        throwsA(
          isA<ProductApiException>().having(
            (e) => e.code,
            'code',
            'INVALID_SERVER',
          ),
        ),
      );
    },
  );

  test(
    'tokens and pending jobs are scoped to origin and user; 401 clears session',
    () async {
      final vault = Vault();
      final session = ProductSession(
        vault: vault,
        api: ProductApi(
          baseUrl: 'https://a.example',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/login')) {
              return ok({
                'token': 'token-a',
                'user': {'id': 'alice', 'username': 'alice'},
              });
            }
            if (request.url.path.endsWith('/provider')) {
              return ok({
                'configured': true,
                'provider': 'openai',
                'model': 'model',
              });
            }
            return http.Response('{"error":{"code":"UNAUTHORIZED"}}', 401);
          }),
        ),
      );
      addTearDown(session.dispose);
      await session.authenticate('login', 'alice', 'private-password');
      await session.savePending({
        'key': 'first-request',
        'prompt': 'Private input',
      });
      final other = ProductSession(
        vault: vault,
        api: ProductApi(baseUrl: 'https://b.example'),
      );
      addTearDown(other.dispose);
      expect(await vault.read(other.tokenKey), isNull);
      session.user = const ProductUser(id: 'bob', username: 'bob');
      expect(await session.pending(), isNull);
      await expectLater(
        session.run(session.api.me),
        throwsA(isA<ProductApiException>()),
      );
      expect(session.user, isNull);
      expect(await vault.read(session.tokenKey), isNull);
    },
  );

  testWidgets(
    'restore shows jobs, provider screen, and logout removes private state',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final vault = Vault();
      final key = GlobalKey();
      final tokenKey = ProductSession(
        api: ProductApi(baseUrl: 'https://api.example'),
        vault: vault,
      ).tokenKey;
      vault.values[tokenKey] = 'token-a';
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/me')) {
          return ok({'id': 'alice', 'username': 'alice'});
        }
        if (request.url.path.endsWith('/provider')) {
          return ok({
            'configured': true,
            'provider': 'openai',
            'model': 'chosen-model',
          });
        }
        if (request.url.path.endsWith('/jobs')) return ok([job]);
        if (request.url.path.endsWith('/jobs/job-a')) return ok(job);
        if (request.url.path.endsWith('/skills')) return ok([]);
        return ok({});
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: WangsaTheme.forBrightness(Brightness.light),
            home: ProductApp(
              apiBaseUrl: 'https://api.example',
              vault: vault,
              httpClient: client,
            ),
          ),
        ),
      );
      await frames(tester);
      expect(find.text('Laporan mingguan'), findsOneWidget);
      await capture(tester, key, 'phone-jobs');
      await tester.tap(find.text('Laporan mingguan'));
      await frames(tester);
      expect(find.text('Hasil pekerjaan'), findsOneWidget);
      await capture(tester, key, 'phone-result');
      await tester.pageBack();
      await frames(tester);
      await tester.tap(find.text('Akun'));
      await frames(tester);
      await tester.tap(find.text('Keluar dari akun'));
      await frames(tester);
      expect(find.text('Selamat datang kembali.'), findsOneWidget);
      expect(find.text('Laporan mingguan'), findsNothing);
      expect(vault.values[tokenKey], isNull);
      await capture(tester, key, 'phone-login');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('uncertain create retries same key and content', (tester) async {
    final requests = <http.Request>[];
    final session = ProductSession(
      vault: Vault(),
      api: ProductApi(
        baseUrl: 'https://api.example',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) throw http.ClientException('disconnected');
          return ok(job, 202);
        }),
      ),
    )..user = const ProductUser(id: 'alice', username: 'alice');
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ProductJobForm(session: session),
      ),
    );
    await frames(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Kebutuhanmu'),
      'Susun laporan.',
    );
    await tester.scrollUntilVisible(
      find.text('Mulai pekerjaan'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Mulai pekerjaan'));
    await frames(tester);
    await tester.scrollUntilVisible(
      find.text('Periksa permintaan'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Periksa permintaan'), findsOneWidget);
    final pending = await session.pending();
    expect(pending!['prompt'], 'Susun laporan.');
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Periksa permintaan'),
    );
    await tester.pump();
    await tester.tap(find.text('Periksa permintaan'));
    await frames(tester);
    expect(requests.length, 2);
    expect(
      requests[0].headers['Idempotency-Key'],
      requests[1].headers['Idempotency-Key'],
    );
    expect(requests[0].body, requests[1].body);
    expect(await session.pending(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('draft requires review before activation at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var activated = false;
    final session = ProductSession(
      vault: Vault(),
      api: ProductApi(
        baseUrl: 'https://api.example',
        httpClient: MockClient((_) async {
          activated = true;
          return ok({});
        }),
      ),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: WangsaTheme.forBrightness(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: ProductSkillPage(
            session: session,
            skill: const ProductSkill(
              id: 'skill-a',
              name: 'laporan-mingguan',
              description: 'Susun laporan dari input baru.',
              content: '# Prosedur\nPeriksa input sebelum menyusun laporan.',
              status: 'draft',
              version: 1,
            ),
          ),
        ),
      ),
    );
    await frames(tester);
    await tester.scrollUntilVisible(
      find.text('Aktifkan prosedur'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Aktifkan prosedur'),
    );
    expect(button.onPressed, isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.ensureVisible(find.text('Aktifkan prosedur'));
    await tester.tap(find.text('Aktifkan prosedur'));
    await frames(tester);
    expect(activated, isTrue);
    expect(find.text('Gunakan untuk pekerjaan baru'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
