import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/whatsapp_templates/whatsapp_templates_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends WhatsAppTemplatesRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  final calls = <Map<String, dynamic>>[];
  String? failure;
  bool pagination = false, noAccounts = false;
  final templates = <Map<String, dynamic>>[
    {
      'id': '999',
      'name': 'solicitud',
      'language': 'es',
      'category': 'UTILITY',
      'status': 'APPROVED',
      'components': [
        {
          'type': 'BODY',
          'text': 'Hola {{1}}',
          'example': {
            'body_text': [
              ['Ana'],
            ],
          },
        },
      ],
    },
  ];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> body) async {
    calls.add(body);
    if (failure != null) {
      throw FunctionException(status: 400, details: {'error': failure});
    }
    return switch (body['action']) {
      'accounts' => {
        'accounts': noAccounts
            ? []
            : [
                {'id': 'account', 'name': 'Empresa', 'waba_id': '123'},
              ],
      },
      'list' => {
        'templates': [
          ...templates,
          if (pagination && body['after'] != null)
            {...templates.single, 'id': '1001', 'name': 'segunda'},
        ],
        'after': pagination && body['after'] == null ? 'cursor' : null,
      },
      'create' => {'id': '1000', 'status': 'PENDING'},
      _ => {'success': true},
    };
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _Repository repo, {
    bool mobile = false,
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(390, 844)
        : const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhatsAppTemplatesPanel(tenantId: 'tenant', repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String label) async {
    final f = find.text(label);
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  Future<void> enter(WidgetTester t, String label, String value) async {
    final f = find.widgetWithText(TextField, label);
    await t.ensureVisible(f);
    await t.enterText(f, value);
    await t.pumpAndSettle();
  }

  testWidgets(
    'creates real text template with variables footer and button in selected tenant',
    (t) async {
      final repo = _Repository();
      await open(t, repo);
      expect(find.text('solicitud · es'), findsOneWidget);
      await tap(t, 'Crear plantilla');
      await enter(t, 'Nombre (minúsculas, números y _)', 'pedido_actualizado');
      await enter(t, 'Encabezado de texto (opcional)', 'Estado del pedido');
      await enter(
        t,
        'Cuerpo del mensaje',
        'Hola {{1}}, tu pedido fue actualizado.',
      );
      await enter(
        t,
        'Ejemplos del cuerpo: uno por línea, en orden {{1}}, {{2}}',
        'Ana',
      );
      await enter(t, 'Pie de página (opcional)', 'ITONE');
      await tap(t, 'Añadir botón');
      await enter(t, 'Texto del botón', 'Entendido');
      await tap(t, 'Crear y enviar a Meta');
      final sent = repo.calls.firstWhere((b) => b['action'] == 'create');
      expect(sent['tenant_id'], 'tenant');
      expect(sent['account_id'], 'account');
      final template = sent['template'] as Map;
      expect(template['body_examples'], ['Ana']);
      expect((template['buttons'] as List).single['type'], 'QUICK_REPLY');
      expect(find.textContaining('Creada en Meta. ID: 1000'), findsOneWidget);
      expect(find.textContaining('No implica aprobación'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('edits existing components without changing immutable fields', (
    t,
  ) async {
    final repo = _Repository();
    await open(t, repo);
    await tap(t, 'Editar');
    expect(
      t
          .widget<TextField>(
            find.widgetWithText(TextField, 'Nombre (minúsculas, números y _)'),
          )
          .enabled,
      isFalse,
    );
    await enter(t, 'Cuerpo del mensaje', 'Hola {{1}}, recibimos tu solicitud.');
    await tap(t, 'Guardar cambios en Meta');
    final sent = repo.calls.firstWhere((b) => b['action'] == 'edit');
    expect(sent['template_id'], '999');
    expect(
      (sent['template'] as Map)['body'],
      'Hola {{1}}, recibimos tu solicitud.',
    );
    expect(find.textContaining('Meta confirmó la edición'), findsOneWidget);
  });
  testWidgets('deletion requires confirmation and reports backend failure', (
    t,
  ) async {
    final repo = _Repository();
    await open(t, repo);
    await tap(t, 'Eliminar');
    await tap(t, 'Cancelar');
    expect(repo.calls.where((b) => b['action'] == 'delete'), isEmpty);
    await tap(t, 'Eliminar');
    repo.failure = 'Meta rechazó la operación (código 190).';
    await tap(t, 'Eliminar de Meta');
    expect(find.textContaining('Meta rechazó'), findsOneWidget);
    expect(find.text('Meta confirmó la eliminación.'), findsNothing);
  });
  testWidgets('mobile editor renders and advanced media is read-only', (
    t,
  ) async {
    final repo = _Repository();
    repo.templates.single['components'] = [
      {'type': 'HEADER', 'format': 'IMAGE'},
      {'type': 'BODY', 'text': 'Hola'},
    ];
    await open(t, repo, mobile: true);
    await tap(t, 'Editar');
    expect(find.textContaining('formatos avanzados'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Guardar cambios en Meta'),
          )
          .onPressed,
      isNull,
    );
    expect(t.takeException(), isNull);
  });
  testWidgets('paginates without duplicating templates and confirms deletion', (
    t,
  ) async {
    final repo = _Repository()..pagination = true;
    await open(t, repo);
    await tap(t, 'Cargar más');
    expect(find.text('solicitud · es'), findsOneWidget);
    expect(find.text('segunda · es'), findsOneWidget);
    expect(repo.calls.last['after'], 'cursor');
    expect(repo.calls.last['account_id'], 'account');
    await t.ensureVisible(find.text('Eliminar').first);
    await t.tap(find.text('Eliminar').first);
    await t.pumpAndSettle();
    await tap(t, 'Eliminar de Meta');
    final sent = repo.calls.firstWhere((b) => b['action'] == 'delete');
    expect(sent['template_id'], '999');
    expect(find.text('Meta confirmó la eliminación.'), findsOneWidget);
  });
  testWidgets(
    'unconfigured account disables creation and never sends requests to Meta',
    (t) async {
      final repo = _Repository()..noAccounts = true;
      await open(t, repo);
      expect(find.textContaining('Conecta una cuenta'), findsOneWidget);
      expect(repo.calls.map((c) => c['action']), ['accounts']);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Crear plantilla'),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('mobile creation shows errors without false success', (t) async {
    final repo = _Repository();
    await open(t, repo, mobile: true);
    await tap(t, 'Crear plantilla');
    await enter(t, 'Nombre (minúsculas, números y _)', 'seguimiento');
    await enter(t, 'Cuerpo del mensaje', 'Recibimos tu solicitud.');
    await tap(t, 'Añadir botón');
    await enter(t, 'Texto del botón', 'Gracias');
    repo.failure = 'La cuenta no tiene token propio.';
    await tap(t, 'Crear y enviar a Meta');
    expect(find.text('La cuenta no tiene token propio.'), findsOneWidget);
    expect(find.textContaining('Creada en Meta.'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
