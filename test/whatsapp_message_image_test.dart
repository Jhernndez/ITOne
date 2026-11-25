import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/message_image.dart';

void main() {
  testWidgets(
    'automatic image load shows progress and ignores an old tenant response',
    (t) async {
      final old = Completer<Uint8List>();
      final current = Completer<Uint8List>();
      Widget page(String tenant, Completer<Uint8List> load) => MaterialApp(
        home: Scaffold(
          body: WhatsAppMessageImage(
            tenantId: tenant,
            messageId: 'message',
            loader: () => load.future,
          ),
        ),
      );
      await t.pumpWidget(page('first', old));
      expect(find.text('Cargando imagen…'), findsOneWidget);
      await t.pumpWidget(page('second', current));
      old.completeError(StateError('old tenant'));
      await t.pump();
      expect(find.text('Cargando imagen…'), findsOneWidget);
      expect(find.text('Reintentar imagen'), findsNothing);
      current.completeError(StateError('offline'));
      await t.pumpAndSettle();
      expect(find.text('Reintentar imagen'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'image downloads automatically, renders and opens zoom without downloading again',
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
      expect(loads, 1);
      expect(find.text('Ver imagen'), findsNothing);
      await t.pumpAndSettle();
      expect(loads, 1);
      expect(find.byType(Image), findsOneWidget);
      await t.tap(find.byType(Image));
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await t.tap(find.text('Cerrar'));
      await t.pumpAndSettle();
      expect(loads, 1);
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
    await t.pumpAndSettle();
    expect(find.text('Reintentar imagen'), findsOneWidget);
    expect(
      find.text('No se pudo cargar la imagen. Intenta de nuevo.'),
      findsOneWidget,
    );
  });
}
