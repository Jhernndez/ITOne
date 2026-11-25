import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/message_image.dart';

void main() {
  testWidgets(
    'image downloads only on request, renders and opens zoom dialog',
    (t) async {
      var loads = 0;
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=',
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhatsAppMessageImage(
              tenantId: 'tenant',
              messageId: 'message',
              loader: () async {
                loads++;
                return bytes;
              },
            ),
          ),
        ),
      );
      expect(loads, 0);
      await t.tap(find.text('Ver imagen'));
      await t.pumpAndSettle();
      expect(loads, 1);
      expect(find.byType(Image), findsOneWidget);
      await t.tap(find.byType(Image));
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await t.tap(find.text('Cerrar'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('image load errors offer explicit retry', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhatsAppMessageImage(
            tenantId: 'tenant',
            messageId: 'message',
            loader: () async => throw StateError('offline'),
          ),
        ),
      ),
    );
    await t.tap(find.text('Ver imagen'));
    await t.pumpAndSettle();
    expect(find.text('Reintentar imagen'), findsOneWidget);
    expect(
      find.text('No se pudo cargar la imagen. Intenta de nuevo.'),
      findsOneWidget,
    );
  });
}
