import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp/number_access_dialog.dart';

void main() {
  testWidgets('assigns a number only to the selected user and company', (
    tester,
  ) async {
    (String, String, String, bool)? change;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhatsAppNumberAccessDialog(
            tenantId: 'company',
            userId: 'agent',
            userName: 'Agente',
            loadAccess: (tenant, user) async => (
              accounts: [
                {
                  'id': 'number-1',
                  'name': 'Línea uno',
                  'display_phone_number': '123',
                },
                {
                  'id': 'number-2',
                  'name': 'Línea dos',
                  'display_phone_number': '456',
                },
              ],
              assigned: {'number-1'},
            ),
            setAccess: (tenant, account, user, allowed) async {
              change = (tenant, account, user, allowed);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Línea uno'),
          )
          .value,
      true,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Línea dos'),
          )
          .value,
      false,
    );
    await tester.tap(find.widgetWithText(SwitchListTile, 'Línea dos'));
    await tester.pumpAndSettle();
    expect(change, ('company', 'number-2', 'agent', true));
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Línea dos'),
          )
          .value,
      true,
    );
  });
}
