import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/message_status.dart';

void main() {
  for (final entry in {
    'accepted': 'Aceptado por Meta; pendiente de envío',
    'sent': 'Enviado',
    'delivered': 'Entregado',
    'read': 'Leído',
    'failed': 'No entregado',
  }.entries) {
    testWidgets('shows local time and truthful status ${entry.key}', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhatsAppMessageStatus(
              timestamp: DateTime(2026, 11, 25, 18, 5).toIso8601String(),
              outbound: true,
              status: entry.key,
            ),
          ),
        ),
      );
      expect(find.text('18:05'), findsOneWidget);
      expect(find.byTooltip(entry.value), findsOneWidget);
      if (entry.key == 'read') {
        expect(t.widget<Icon>(find.byType(Icon)).color, Colors.blue);
      }
    });
  }
  testWidgets('incoming messages have time but no outgoing ticks', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WhatsAppMessageStatus(
            timestamp: 'invalid',
            outbound: false,
            status: 'accepted',
          ),
        ),
      ),
    );
    expect(find.text('Hora no disponible'), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
  });
  test('realtime messages insert update delete without duplicates and retain media', () {
    final original = <Map<String, dynamic>>[
      {
        'id': 'first',
        'created_at': '2026-11-25T12:00:00Z',
        'media_id': '123',
        'delivery_status': 'accepted',
      },
    ];
    var result = mergeWhatsAppMessage(original, {
      'id': 'first',
      'delivery_status': 'read',
    }, deleted: false);
    expect(result.length, 1);
    expect(result.first['media_id'], '123');
    expect(result.first['delivery_status'], 'read');
    result = mergeWhatsAppMessage(result, {
      'id': 'earlier',
      'created_at': '2026-11-25T11:00:00Z',
    }, deleted: false);
    expect(result.first['id'], 'earlier');
    result = mergeWhatsAppMessage(result, {'id': 'first'}, deleted: true);
    expect(result.length, 1);
    expect(original.first['delivery_status'], 'accepted');
  });
}
