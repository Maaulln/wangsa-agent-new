import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wangsa_mobile/api/api_endpoints.dart';
import 'package:wangsa_mobile/product/automation_workspace.dart';
import 'package:wangsa_mobile/product/product_api.dart';
import 'package:wangsa_mobile/product/product_models.dart';
import 'package:wangsa_mobile/product/product_session.dart';
import 'package:wangsa_mobile/llm/llm_settings_controller.dart';

class Vault implements KeyVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

http.Response ok(Object data, [int status = 200]) =>
    http.Response(jsonEncode({'data': data}), status);

void main() {
  test('product API maps chat gateway to product gateway', () {
    expect(productApiBaseUrl('http://10.0.2.2:9901'), 'http://10.0.2.2:9902');
    expect(productApiBaseUrl('https://wangsa.example'), 'https://wangsa.example');
  });

  testWidgets('automation workspace exposes new creation contract', (tester) async {
    final session = ProductSession(
      vault: Vault(),
      api: ProductApi(
        baseUrl: 'https://api.example',

        httpClient: MockClient((request) async => ok({
          'id': 'job-a',
          'title': 'Cek PENS',
          'prompt': 'Read only',
          'status': 'awaiting_approval',
          'events': [],
        })),
      ),
    )
      ..user = const ProductUser(id: 'alice', username: 'alice');
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(home: AutomationWorkspace(session: session)));
    expect(find.text('Buat automation'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Nama automation'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Apa yang harus dilakukan agent?'), findsOneWidget);
    expect(find.text('Susun automation'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'NetID situs (opsional)'), findsNothing);
    expect(find.widgetWithText(TextField, 'Kata sandi situs (opsional)'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Nama automation'), 'Cek PENS');
    await tester.enterText(
      find.widgetWithText(TextField, 'Apa yang harus dilakukan agent?'),
      'Buka CAS PENS read-only. Jangan isi credential dan jangan submit.',
    );
    await tester.tap(find.text('Susun automation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Menunggu persetujuan'), findsOneWidget);
  });
}
