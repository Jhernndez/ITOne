import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/automations/demo_agenda.dart';

void main() {
  testWidgets('shows fictional appointments for the selected tenant', (
    tester,
  ) async {
    String? tenant;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DemoAgenda(
            tenantId: 'sana',
            loadAgenda: (id) async {
              tenant = id;
              return {
                'installed': true,
                'appointments': [
                  {
                    'starts_at': '2030-01-02T14:00:00Z',
                    'doctor': 'Dra. Laura Ejemplo',
                    'patient': 'Ana Ejemplo',
                    'patient_code': 'DEMO-001',
                    'status': 'Reservada',
                  },
                ],
              };
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tenant, 'sana');
    expect(find.textContaining('Dra. Laura Ejemplo'), findsOneWidget);
    expect(find.textContaining('Ana Ejemplo'), findsOneWidget);
    expect(find.text('Reservada'), findsOneWidget);
  });

  testWidgets('explains when the demo has not been installed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DemoAgenda(
            tenantId: 'other',
            loadAgenda: (_) async => {'installed': false},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Crea la demo de citas'), findsOneWidget);
  });
}
