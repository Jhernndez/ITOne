import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/whatsapp_connection_header.dart';

void main() {
  for (final (configured, mode, state) in [
    (true, 'coexistence', 'Estado de la conexión: Activa'),
    (true, 'cloud_api', 'Estado de la conexión: requiere autorización'),
    (true, 'unknown', 'Estado de la conexión: requiere autorización'),
    (false, 'cloud_api', 'Estado de la conexión: sin conectar'),
  ]) {
    testWidgets('tenant header $configured $mode has simple honest status', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhatsAppConnectionHeader(
              configured: configured,
              onboardingMode: mode,
              statusLabel: 'Activa',
            ),
          ),
        ),
      );
      expect(find.text(state), findsOneWidget);
      expect(find.textContaining('no garantiza la entrega'), findsOneWidget);
      expect(find.textContaining('Cloud API'), findsNothing);
      expect(find.textContaining('Validar conexión con Meta'), findsNothing);
      expect(find.textContaining('No necesitas copiar tokens'), findsOneWidget);
      if (mode != 'coexistence') {
        expect(find.text('Conectar WhatsApp Business'), findsOneWidget);
      }
    });
  }
}
