import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/cloud_number_form.dart';

void main() {
  testWidgets('submits the selected tenant and clears the token', (
    tester,
  ) async {
    Map<String, String>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WhatsAppCloudNumberForm(
              tenantId: 'company',
              submit: (data) async {
                submitted = data;
                return {'ok': true, 'message': 'Número guardado'};
              },
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'ID de cuenta de WhatsApp Business'),
      '111',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone Number ID'),
      '222',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Token de acceso'),
      'secret-token',
    );
    await tester.tap(find.text('Validar y guardar número'));
    await tester.pumpAndSettle();
    expect(submitted, {
      'tenant_id': 'company',
      'waba_id': '111',
      'phone_number_id': '222',
      'access_token': 'secret-token',
    });
    final token = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Token de acceso'),
    );
    expect(token.obscureText, true);
    expect(token.controller!.text, isEmpty);
    expect(find.text('Número guardado'), findsOneWidget);
  });

  testWidgets('blocks incomplete data without invoking the server', (
    tester,
  ) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WhatsAppCloudNumberForm(
              tenantId: 'company',
              submit: (_) async {
                called = true;
                return {'ok': true};
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Validar y guardar número'));
    await tester.pumpAndSettle();
    expect(called, false);
    expect(
      find.textContaining('Completa los dos identificadores'),
      findsOneWidget,
    );
  });
}
