import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:itone/features/automations/bot_controls.dart';

class _Repository extends BotRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  bool enabled = false;
  String? tenant;
  String? account;
  String? failure;
  @override
  Future<Map<String, List<Map<String, dynamic>>>> load(
    String tenantId,
  ) async => {
    'accounts': [
      {'id': 'account-1', 'name': 'Empresa', 'display_phone_number': '+57 123'},
    ],
    'versions': [
      {'flow_id': 'flow-1', 'version': 2, 'name': 'Atención'},
    ],
    'bindings': enabled
        ? [
            {
              'account_id': 'account-1',
              'flow_id': 'flow-1',
              'version': 2,
              'enabled': true,
            },
          ]
        : [],
    'failures': [],
  };
  @override
  Future<void> configure(
    String tenantId,
    String accountId,
    Map<String, dynamic>? version,
    bool value,
  ) async {
    if (failure != null) throw PostgrestException(message: failure!);
    tenant = tenantId;
    account = accountId;
    enabled = value;
  }
}

void main() {
  testWidgets(
    'bot remains off until number/version and real-send confirmation; disabling persists',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BotSettingsPanel(tenantId: 'company', repository: repository),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bot desactivado'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empresa +57 123').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Atención · v2').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activar versión seleccionada'));
      await tester.pumpAndSettle();
      expect(repository.enabled, isFalse);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(repository.tenant, isNull);
      await tester.tap(find.text('Activar versión seleccionada'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activar bot'));
      await tester.pumpAndSettle();
      expect(repository.enabled, isTrue);
      expect(repository.tenant, 'company');
      expect(repository.account, 'account-1');
      expect(find.text('Bot activo · versión 2'), findsOneWidget);
      await tester.tap(find.text('Desactivar bot'));
      await tester.pumpAndSettle();
      expect(repository.enabled, isFalse);
      expect(find.text('Bot desactivado'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
