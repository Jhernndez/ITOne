import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/automations/api_mapping_dialog.dart';

void main() {
  testWidgets(
    'visual mapping preserves values and can select a flow variable',
    (tester) async {
      ({String query, String body})? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<({String query, String body})>(
                    context: context,
                    builder: (_) => const ApiMappingDialog(
                      query: '{"tipo":"fijo"}',
                      body: '{}',
                      variables: ['cedula'],
                    ),
                  );
                },
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agregar dato').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Nombre del dato').last,
        'documento',
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Origen').last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('cedula').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aplicar'));
      await tester.pumpAndSettle();
      expect(jsonDecode(result!.query), {'tipo': 'fijo'});
      expect(jsonDecode(result!.body), {'documento': '{{cedula}}'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsupported advanced JSON remains untouched', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ApiMappingDialog(
            query: '{"page":1}',
            body: '{}',
            variables: [],
          ),
        ),
      ),
    );
    expect(find.textContaining('solo edita objetos simples'), findsOneWidget);
    expect(find.text('Aplicar'), findsNothing);
  });

  testWidgets('advanced variable expressions cannot be edited visually', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ApiMappingDialog(
            query: '{}',
            body: '{"dato":"Paciente {{respuesta.nombre}}"}',
            variables: ['respuesta'],
          ),
        ),
      ),
    );
    expect(find.textContaining('variable avanzada'), findsOneWidget);
    expect(find.text('Aplicar'), findsNothing);
  });

  testWidgets('variable can be replaced with fixed text', (tester) async {
    ({String query, String body})? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<({String query, String body})>(
                  context: context,
                  builder: (_) => const ApiMappingDialog(
                    query: '{}',
                    body: '{"documento":"{{cedula}}"}',
                    variables: ['cedula'],
                  ),
                );
              },
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Origen'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Texto fijo').last);
    await tester.pumpAndSettle();
    final value = find.widgetWithText(TextField, 'Valor fijo');
    expect(tester.widget<TextField>(value).controller!.text, isEmpty);
    await tester.enterText(value, 'DEMO-001');
    await tester.tap(find.text('Aplicar'));
    await tester.pumpAndSettle();
    expect(jsonDecode(result!.body), {'documento': 'DEMO-001'});
  });

  testWidgets('duplicate names can be corrected without losing values', (
    tester,
  ) async {
    ({String query, String body})? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<({String query, String body})>(
                  context: context,
                  builder: (_) => const ApiMappingDialog(
                    query: '{"dato":"uno"}',
                    body: '{}',
                    variables: [],
                  ),
                );
              },
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agregar dato').first);
    await tester.pumpAndSettle();
    final names = find.widgetWithText(TextField, 'Nombre del dato');
    await tester.enterText(names.last, 'dato');
    await tester.tap(find.text('Aplicar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('nombre único'), findsOneWidget);
    await tester.enterText(names.last, 'otro');
    await tester.tap(find.text('Aplicar'));
    await tester.pumpAndSettle();
    expect(jsonDecode(result!.query), {'dato': 'uno', 'otro': ''});
  });
}
