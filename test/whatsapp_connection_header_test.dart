import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/whatsapp_connection_header.dart';

void main() {
  for (final (mode, expected) in [
    ('cloud_api', 'WhatsApp · Conexión anterior Cloud API · sin coexistencia'),
    ('coexistence', 'WhatsApp · Coexistencia'),
    ('unknown', 'WhatsApp · Modalidad por verificar'),
  ]) {
    testWidgets('labels $mode without claiming Meta delivery capability', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhatsAppConnectionHeader(
              configured: true,
              onboardingMode: mode,
              statusLabel: 'Activa',
            ),
          ),
        ),
      );
      expect(find.text(expected), findsOneWidget);
      expect(
        find.text('Estado de la conexión en ITONE: Activa'),
        findsOneWidget,
      );
      expect(
        find.textContaining('no certifica que Meta permita enviar'),
        findsOneWidget,
      );
    });
  }
  testWidgets('unconfigured connection does not claim coexistence', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WhatsAppConnectionHeader(
            configured: false,
            onboardingMode: 'cloud_api',
            statusLabel: 'Pendiente',
          ),
        ),
      ),
    );
    expect(find.text('Conectar WhatsApp Business'), findsOneWidget);
    expect(find.textContaining('sin coexistencia'), findsNothing);
  });
}
