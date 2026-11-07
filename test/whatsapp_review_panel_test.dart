import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp_review/whatsapp_review_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends WhatsAppReviewRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  final calls = <String>[];
  String? failure;
  @override
  Future<Map<String, dynamic>> call(String tenantId, String action) async {
    calls.add('$tenantId:$action');
    if (failure != null) {
      throw FunctionException(status: 409, details: {'error': failure});
    }
    return action == 'status'
        ? {
            'phone_number_id': '123456',
            'recipient': '573000000000',
            'template': 'jaspers_market_order_confirmation_v1',
            'language': 'en_US',
          }
        : {'provider_message_id': 'wamid.example', 'status': 'accepted'};
  }
}

void main() {
  Future<void> open(WidgetTester tester, _Repository repository) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhatsAppReviewPanel(
            tenantId: 'company',
            repository: repository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'requires confirmation, sends from selected tenant and shows accepted not delivered',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      final button = find.widgetWithText(
        FilledButton,
        'Enviar plantilla real de prueba',
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(repository.calls, ['company:status']);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(repository.calls, ['company:status', 'company:send']);
      expect(find.text('ID: wamid.example'), findsOneWidget);
      expect(
        find.textContaining('Aceptado no significa entregado'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'missing configuration is explicit and retry loads server state',
    (tester) async {
      final repository = _Repository()
        ..failure = 'Completa los secretos de revisión en Supabase';
      await open(tester, repository);
      expect(find.textContaining('Completa los secretos'), findsOneWidget);
      expect(find.text('Enviar plantilla real de prueba'), findsNothing);
      repository.failure = null;
      final retry = find.text('Actualizar configuración de prueba');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text('Enviar plantilla real de prueba'), findsOneWidget);
    },
  );
  testWidgets('failed send does not show success or message ID', (
    tester,
  ) async {
    final repository = _Repository();
    await open(tester, repository);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    repository.failure = 'Meta rechazó el envío (código 190).';
    final send = find.text('Enviar plantilla real de prueba');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.textContaining('Meta rechazó'), findsOneWidget);
    expect(find.text('Meta aceptó el mensaje'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
