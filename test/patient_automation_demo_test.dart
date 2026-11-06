import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/automations/automation_demo.dart';

void main() {
  Future<void> tap(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester, {
    bool mobile = false,
    String tenant = 'Empresa Uno',
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(390, 844)
        : const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: AutomationDemo(key: ValueKey(tenant), tenantName: tenant),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'Probar automatización');
  }

  Future<void> enter(WidgetTester tester, String label, String value) async {
    final finder = find.widgetWithText(TextField, label);
    await tester.ensureVisible(finder);
    await tester.enterText(finder, value);
    await tap(tester, 'Continuar prueba');
  }

  testWidgets(
    'EPS requests provider and service then transfers on API failure without confirming',
    (tester) async {
      await open(tester);
      await tap(tester, 'EPS');
      await tap(tester, 'Continuar prueba');
      expect(
        find.text('Escribe entre 1 y 200 caracteres ficticios.'),
        findsOneWidget,
      );
      await enter(tester, 'EPS ficticia', 'EPS de prueba');
      await enter(
        tester,
        'Servicio requerido (ficticio)',
        'Servicio de prueba',
      );
      expect(find.text('Examen médico ficticio (opcional)'), findsNothing);
      await tap(tester, 'Simular fallo de API');
      expect(
        find.textContaining('No fue posible consultar el sistema.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('sin confirmar la solicitud ni una cita'),
        findsOneWidget,
      );
      expect(
        find.text('Prueba finalizada · Sin cambios en sistemas reales.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('no se hizo ninguna llamada real'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'particular accepts optional exam and denial requires a visible reason',
    (tester) async {
      await open(tester);
      await tap(tester, 'Particular');
      await enter(tester, 'Servicio requerido (ficticio)', 'Servicio ficticio');
      await enter(
        tester,
        'Examen médico ficticio (opcional)',
        'Examen de demostración',
      );
      await tap(tester, 'Agente deniega solicitud');
      await tap(tester, 'Continuar prueba');
      expect(
        find.text('Escribe entre 1 y 200 caracteres ficticios.'),
        findsOneWidget,
      );
      expect(find.text('Continuar con atención humana'), findsNothing);
      await enter(
        tester,
        'Motivo de denegación (ficticio)',
        'Servicio no disponible en este ejemplo',
      );
      expect(
        find.textContaining('Motivo: Servicio no disponible en este ejemplo'),
        findsOneWidget,
      );
      await tap(tester, 'Continuar con atención humana');
      expect(
        find.textContaining('No se asignó ningún agente real'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile supports skipping exam, finishing pending and restarting cleanly',
    (tester) async {
      await open(tester, mobile: true);
      await tap(tester, 'Particular');
      await enter(tester, 'Servicio requerido (ficticio)', 'Servicio ficticio');
      await tap(tester, 'Continuar sin examen');
      await tap(tester, 'Finalizar pendiente');
      expect(find.textContaining('No se creó ninguna cita.'), findsOneWidget);
      await tap(tester, 'Reiniciar prueba');
      expect(find.text('EPS'), findsOneWidget);
      expect(find.text('Particular'), findsOneWidget);
      expect(find.text('Servicio ficticio'), findsNothing);
      expect(
        find.text('Prueba finalizada · Sin cambios en sistemas reales.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the scenario or switching tenant discards simulated conversation',
    (tester) async {
      await open(tester);
      await tap(tester, 'EPS');
      await enter(tester, 'EPS ficticia', 'Dato ficticio de empresa uno');
      await tap(tester, 'Volver a reglas de horario');
      await tap(tester, 'Probar automatización');
      expect(find.text('Dato ficticio de empresa uno'), findsNothing);
      await tap(tester, 'EPS');
      await enter(tester, 'EPS ficticia', 'Otro ejemplo ficticio');
      await open(tester, tenant: 'Empresa Dos');
      expect(find.text('Otro ejemplo ficticio'), findsNothing);
      expect(find.textContaining('Bienvenido a Empresa Dos.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
