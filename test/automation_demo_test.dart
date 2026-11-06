import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/automations/automation_demo.dart';

void main() {
  testWidgets('out-of-hours preview uses the selected time and rule toggles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AutomationDemo(tenantName: 'Empresa'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final time = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<int> && widget.initialValue == 10,
    );
    await tester.tap(time);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('20:00').last,
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('20:00').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simular mensaje'));
    await tester.pumpAndSettle();
    expect(find.text('Respuesta simulada · Fuera de horario'), findsOneWidget);
    expect(find.text('Respuesta simulada · Bienvenida'), findsNothing);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Fuera de horario'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simular mensaje'));
    await tester.pumpAndSettle();
    expect(find.text('Respuesta simulada · Bienvenida'), findsOneWidget);
  });

  DemoAutomationResult run({
    int hour = 10,
    int opening = 8,
    int closing = 18,
    bool fresh = true,
    bool agent = false,
    bool away = true,
    bool welcome = true,
  }) => simulateAutomation(
    outOfHoursEnabled: away,
    welcomeEnabled: welcome,
    isNewConversation: fresh,
    agentAttending: agent,
    hour: hour,
    openingHour: opening,
    closingHour: closing,
    welcomeMessage: 'Bienvenido',
    awayMessage: 'No estamos',
  );

  test('executes only the first matching rule with human handoff taking precedence', () {
    expect(run().rule, DemoAutomation.welcome);
    expect(run(hour: 20).rule, DemoAutomation.outOfHours);
    expect(run(hour: 20).response, 'No estamos');
    expect(
      run(hour: 20).trace.join(' '),
      isNot(contains('Bienvenida coincide')),
    );
    expect(run(hour: 20, agent: true).response, isNull);
    expect(run(fresh: false).response, isNull);
    expect(run(hour: 20, fresh: false).rule, DemoAutomation.outOfHours);
    expect(run(hour: 20, away: false).rule, DemoAutomation.welcome);
    expect(run(away: false, welcome: false).response, isNull);
  });

  test(
    'opening is inclusive, closing exclusive, including overnight hours',
    () {
      expect(run(hour: 8).rule, DemoAutomation.welcome);
      expect(run(hour: 18).rule, DemoAutomation.outOfHours);
      expect(
        run(hour: 22, opening: 22, closing: 6).rule,
        DemoAutomation.welcome,
      );
      expect(
        run(hour: 2, opening: 22, closing: 6).rule,
        DemoAutomation.welcome,
      );
      expect(
        run(hour: 6, opening: 22, closing: 6).rule,
        DemoAutomation.outOfHours,
      );
      expect(() => run(opening: 8, closing: 8), throwsArgumentError);
      expect(() => run(hour: 24), throwsArgumentError);
    },
  );

  Future<void> open(
    WidgetTester tester, {
    bool mobile = false,
    String tenant = 'Empresa Uno',
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(390, 844)
        : const Size(1440, 1100);
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
  }

  testWidgets(
    'runs simulated replies with edited text and clears stale results',
    (tester) async {
      await open(tester);
      expect(find.textContaining('no envía mensajes'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Respuesta de Bienvenida'),
        'Bienvenido a la prueba',
      );
      await tester.tap(find.text('Simular mensaje'));
      await tester.pumpAndSettle();
      expect(find.text('Bienvenido a la prueba'), findsNWidgets(2));
      expect(find.text('Respuesta simulada · Bienvenida'), findsOneWidget);
      expect(find.text('Recorrido de esta prueba'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Un agente está atendiendo'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recorrido de esta prueba'), findsNothing);
      await tester.tap(find.text('Simular mensaje'));
      await tester.pumpAndSettle();
      expect(find.text('Sin respuesta automática.'), findsOneWidget);
      expect(find.textContaining('el bot no interviene'), findsOneWidget);
    },
  );

  testWidgets('rejects empty active responses and fake incoming messages', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Respuesta de Bienvenida'),
      '',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mensaje del cliente ficticio'),
      '',
    );
    await tester.tap(find.text('Simular mensaje'));
    await tester.pumpAndSettle();
    expect(
      find.text('Escribe una respuesta para esta regla activa.'),
      findsOneWidget,
    );
    expect(find.text('Escribe un mensaje para simular.'), findsOneWidget);
    expect(find.text('Recorrido de esta prueba'), findsNothing);
  });

  testWidgets(
    'switching companies discards responses and simulated conversations',
    (tester) async {
      await open(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Respuesta de Bienvenida'),
        'Texto de empresa uno',
      );
      await tester.tap(find.text('Simular mensaje'));
      await tester.pumpAndSettle();
      await open(tester, tenant: 'Empresa Dos');
      expect(find.text('Texto de empresa uno'), findsNothing);
      expect(
        find.textContaining('Gracias por contactar a Empresa Dos'),
        findsOneWidget,
      );
      expect(find.text('Recorrido de esta prueba'), findsNothing);
    },
  );

  testWidgets('mobile layout scrolls and can simulate without overflow', (
    tester,
  ) async {
    await open(tester, mobile: true);
    await tester.ensureVisible(find.text('Simular mensaje'));
    await tester.tap(find.text('Simular mensaje'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Recorrido de esta prueba'));
    expect(find.text('Respuesta simulada · Bienvenida'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
