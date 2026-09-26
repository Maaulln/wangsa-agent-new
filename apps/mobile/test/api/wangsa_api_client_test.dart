import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/api/models.dart';
import 'package:wangsa_mobile/api/wangsa_api_client.dart';
import 'package:wangsa_mobile/llm/llm_override.dart';

void main() {
  group('WangsaApiClient.getAgent', () {
    test('memanggil endpoint publik dan mengembalikan Agent', () async {
      late Uri dipanggil;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          dipanggil = request.url;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'id': 'agent-1',
                'name': 'Asisten',
                'purpose': 'Membantu',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.getAgent('agent-1');

      expect(
        dipanggil.toString(),
        'https://api.wangsa.test/api/v1/agents/agent-1',
      );
      expect(result.dataOrNull?.name, 'Asisten');
      expect(result.dataOrNull?.purpose, 'Membantu');
    });

    test('meneruskan kode galat dari server apa adanya', () async {
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'success': false,
              'error': {'code': 'NOT_FOUND', 'message': 'Not found.'},
            }),
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.getAgent('agent-1');

      expect(result.isSuccess, isFalse);
      expect(result.errorOrNull?.code, 'NOT_FOUND');
    });

    test('jaringan mati menjadi RUNTIME_ERROR, bukan lemparan', () async {
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          throw const SocketExceptionStub();
        }),
      );

      final result = await client.getAgent('agent-1');

      expect(result.isSuccess, isFalse);
      expect(result.errorOrNull?.code, 'RUNTIME_ERROR');
    });

    test(
      'server yang tidak pernah menjawab berakhir sebagai RUNTIME_ERROR, bukan menggantung',
      () async {
        final client = WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          requestTimeout: const Duration(milliseconds: 50),
          httpClient: MockClient(
            (request) => Completer<http.Response>().future,
          ),
        );

        final result = await client.getAgent('agent-1');

        expect(result.isSuccess, isFalse);
        expect(result.errorOrNull?.code, 'RUNTIME_ERROR');
      },
    );

    test('badan yang bukan JSON menjadi RUNTIME_ERROR', () async {
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          return http.Response('<html>gateway error</html>', 502);
        }),
      );

      final result = await client.getAgent('agent-1');

      expect(result.isSuccess, isFalse);
      expect(result.errorOrNull?.code, 'RUNTIME_ERROR');
    });
  });

  group('WangsaApiClient.sendMessage', () {
    test('mengirim pesan sebagai JSON ke endpoint pesan', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'Halo juga'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.sendMessage('agent-1', 'Halo');

      expect(terkirim.method, 'POST');
      expect(terkirim.url.path, '/api/v1/agents/agent-1/messages');
      expect(terkirim.headers['content-type'], contains('application/json'));
      expect(jsonDecode(terkirim.body), {'message': 'Halo', 'toolsets': []});
      expect(result.dataOrNull?.response, 'Halo juga');
    });

    test('mengirim capability yang dipilih untuk percakapan baru', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'siap'},
            }),
            200,
          );
        }),
      );

      await client.sendMessage(
        'agent-1',
        'Cari ini',
        toolsets: const ['web', 'vision'],
      );

      expect((jsonDecode(terkirim.body) as Map<String, dynamic>)['toolsets'], [
        'web',
        'vision',
      ]);
    });

    test(
      'mengurai images bawaan Agent: base64 lokal dan URL jarak jauh',
      () async {
        final pngBytes = base64Encode([1, 2, 3, 4]);
        final client = WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'response': 'ini hasilnya',
                  'images': [
                    {
                      'data': pngBytes,
                      'mimeType': 'image/png',
                      'filename': 'a.png',
                    },
                    {
                      'url': 'https://example.com/b.png',
                      'caption': 'keterangan',
                    },
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        final reply = (await client.sendMessage(
          'agent-1',
          'gambar',
        )).dataOrNull!;

        expect(reply.images, hasLength(2));
        expect(reply.images[0].bytes, [1, 2, 3, 4]);
        expect(reply.images[0].mimeType, 'image/png');
        expect(reply.images[0].filename, 'a.png');
        expect(reply.images[1].bytes, isNull);
        expect(reply.images[1].url, 'https://example.com/b.png');
        expect(reply.images[1].caption, 'keterangan');
      },
    );

    test('mengurai files bawaan Agent: dokumen dan audio', () async {
      final pdfBytes = base64Encode([5, 6, 7, 8]);
      final audioBytes = base64Encode([9, 9, 9]);
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'response': 'ini berkasnya',
                'files': [
                  {
                    'data': pdfBytes,
                    'mimeType': 'application/pdf',
                    'filename': 'laporan.pdf',
                    'kind': 'document',
                  },
                  {
                    'data': audioBytes,
                    'mimeType': 'audio/mpeg',
                    'filename': 'balasan.mp3',
                    'kind': 'audio',
                    'caption': 'Halo suara',
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final reply = (await client.sendMessage(
        'agent-1',
        'kirim berkas',
      )).dataOrNull!;

      expect(reply.files, hasLength(2));
      expect(reply.files[0].bytes, [5, 6, 7, 8]);
      expect(reply.files[0].kind, 'document');
      expect(reply.files[0].isAudio, isFalse);
      expect(reply.files[0].filename, 'laporan.pdf');
      expect(reply.files[1].bytes, [9, 9, 9]);
      expect(reply.files[1].kind, 'audio');
      expect(reply.files[1].isAudio, isTrue);
      expect(reply.files[1].caption, 'Halo suara');
    });

    test(
      'tanpa kunci images, balasan tetap terurai dengan daftar gambar kosong',
      () async {
        final client = WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {'response': 'teks saja'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        final reply = (await client.sendMessage('agent-1', 'halo')).dataOrNull!;

        expect(reply.images, isEmpty);
      },
    );

    test(
      'balasan Agent yang tidak kunjung datang berakhir sebagai RUNTIME_ERROR',
      () async {
        final client = WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          replyTimeout: const Duration(milliseconds: 50),
          httpClient: MockClient(
            (request) => Completer<http.Response>().future,
          ),
        );

        final result = await client.sendMessage('agent-1', 'Halo');

        expect(result.isSuccess, isFalse);
        expect(result.errorOrNull?.code, 'RUNTIME_ERROR');
      },
    );

    test('tidak pernah mengirim header identitas atau workspace', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'ok'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await client.sendMessage('agent-1', 'Halo');

      final kunci = terkirim.headers.keys.map((k) => k.toLowerCase());
      expect(kunci, isNot(contains('x-dev-identity')));
      expect(kunci, isNot(contains('x-workspace-id')));
    });

    test('mengambil daftar model deployment', () async {
      late Uri dipanggil;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          dipanggil = request.url;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'provider': 'prov',
                'current': 'model-a',
                'models': ['model-a', 'model-b'],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.getModels('agent-1');

      expect(
        dipanggil.toString(),
        'https://api.wangsa.test/api/v1/agents/agent-1/models',
      );
      expect(result.dataOrNull?.provider, 'prov');
      expect(result.dataOrNull?.current, 'model-a');
      expect(result.dataOrNull?.models, ['model-a', 'model-b']);
    });

    test('menyertakan model, gambar, dan capability kosong bawaan', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'ok'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await client.sendMessage(
        'agent-1',
        'Lihat ini',
        model: 'model-b',
        images: const [
          ChatImage(bytes: [1, 2, 3], mimeType: 'image/png', filename: 'a.png'),
        ],
      );

      expect(jsonDecode(terkirim.body), {
        'message': 'Lihat ini',
        'toolsets': [],
        'model': 'model-b',
        'images': [
          {'data': 'AQID', 'mimeType': 'image/png', 'filename': 'a.png'},
        ],
      });
    });

    test(
      'menyertakan userName dan userBio bila diberikan, tanpanya tidak ada kolom itu sama sekali',
      () async {
        late http.Request terkirim;
        final client = WangsaApiClient(
          baseUrl: 'https://api.wangsa.test',
          httpClient: MockClient((request) async {
            terkirim = request;
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {'response': 'ok'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await client.sendMessage(
          'agent-1',
          'Halo',
          userName: 'Doni',
          userBio: 'santai, bahasa Indonesia',
        );

        expect(jsonDecode(terkirim.body), {
          'message': 'Halo',
          'toolsets': [],
          'userName': 'Doni',
          'userBio': 'santai, bahasa Indonesia',
        });

        await client.sendMessage('agent-1', 'Halo lagi');
        final body = jsonDecode(terkirim.body) as Map<String, dynamic>;
        expect(body.containsKey('userName'), isFalse);
        expect(body.containsKey('userBio'), isFalse);
      },
    );

    test('pesan kosong dengan gambar tetap terkirim', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'ok'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.sendMessage(
        'agent-1',
        '   ',
        images: const [
          ChatImage(bytes: [9]),
        ],
      );

      expect(result.isSuccess, isTrue);
      expect(jsonDecode(terkirim.body)['images'], hasLength(1));
    });

    test('menyertakan override llm bersama capability kosong bawaan', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'ok'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await client.sendMessage(
        'agent-1',
        'Halo',
        llm: const LlmOverride(
          baseURL: 'https://api.example.com/v1',
          apiKey: 'kunci',
          model: 'm/model',
        ),
      );

      expect(jsonDecode(terkirim.body), {
        'message': 'Halo',
        'toolsets': [],
        'llm': {
          'baseURL': 'https://api.example.com/v1',
          'apiKey': 'kunci',
          'model': 'm/model',
        },
      });
    });
  });

  group('WangsaApiClient auth (signup/me/token)', () {
    test('signup memanggil endpoint publik dan mengembalikan token', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'profile': 'budi',
                'token': 'tok-123',
                'configured': false,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.signup('Budi');

      expect(
        terkirim.url.toString(),
        'https://api.wangsa.test/api/v1/auth/signup',
      );
      expect(jsonDecode(terkirim.body), {'username': 'budi'});
      expect(result.dataOrNull?.profile, 'budi');
      expect(result.dataOrNull?.token, 'tok-123');
    });

    test('getMe mengirim Authorization Bearer', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'profile': 'budi', 'configured': true},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..updateToken('tok-123');

      final result = await client.getMe();

      expect(terkirim.headers['Authorization'], 'Bearer tok-123');
      expect(result.dataOrNull?.profile, 'budi');
      expect(result.dataOrNull?.configured, isTrue);
    });

    test('401 dipetakan ke pesan Indonesia dengan kode asli', () async {
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'success': false,
              'error': {
                'code': 'UNAUTHORIZED',
                'message': 'missing or invalid bearer token',
              },
            }),
            401,
            headers: {'content-type': 'application/json'},
          ),
        ),
      )..updateToken('salah');

      final result = await client.getMe();

      expect(result.isSuccess, isFalse);
      expect(result.errorOrNull?.code, 'UNAUTHORIZED');
      expect(result.errorOrNull?.message, contains('Token'));
    });

    test('getBudget mengembalikan ringkasan cap vs spend', () async {
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'enabled': true,
                'daily_usd': 1.0,
                'monthly_usd': null,
                'spent_day': 0.9,
                'spent_month': 0.9,
                'breached': null,
                'alert': true,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..updateToken('tok-123');

      final result = await client.getBudget();

      expect(result.dataOrNull?.dailyUsd, 1.0);
      expect(result.dataOrNull?.alert, isTrue);
      expect(result.dataOrNull?.isBreached, isFalse);
      expect(result.dataOrNull?.dayPct, closeTo(0.9, 0.001));
    });

    test('revokeToken menghapus sesi server', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'revoked': true},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..updateToken('tok-123');

      final result = await client.revokeToken();

      expect(terkirim.method, 'DELETE');
      expect(
        terkirim.url.toString(),
        'https://api.wangsa.test/api/v1/auth/token',
      );
      expect(result.dataOrNull, isTrue);
    });

    test('pesan chat membawa token yang sama', () async {
      late http.Request terkirim;
      final client = WangsaApiClient(
        baseUrl: 'https://api.wangsa.test',
        httpClient: MockClient((request) async {
          terkirim = request;
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'response': 'ok'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..updateToken('tok-123');

      await client.sendMessage('agent-1', 'Halo');

      expect(terkirim.headers['Authorization'], 'Bearer tok-123');
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
