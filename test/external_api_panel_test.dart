import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/external_api/external_api_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeRepository extends ExternalApiRepository {
  FakeRepository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  final calls = <Map<String, dynamic>>[];
  final resources = <Map<String, dynamic>>[
    {
      'id': 'r1',
      'name': 'Pedido',
      'path': '/orders',
      'http_method': 'POST',
      'enabled': true,
      'enabled_for_automation': false,
      'allow_automation_writes': false,
    },
  ];
  @override
  Future<List<Map<String, dynamic>>> list(String tenantId) async => [
    {
      'id': 'api',
      'name': 'Ventas',
      'base_url': 'https://example.com',
      'auth_type': 'bearer_token',
      'enabled': true,
      'tenant_api_resources': resources,
    },
  ];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> body) async {
    calls.add(body);
    if (body['action'] == 'execute_resource') {
      return {
        'ok': false,
        'status_code': 422,
        'body': {'error': 'rechazado'},
      };
    }
    return {'ok': true, 'status_code': 200, 'body': 'listo'};
  }

  @override
  Future<void> saveResource(
    String tenantId,
    String integrationId,
    String? id,
    Map<String, dynamic> values,
  ) async {
    calls.add({
      'tenant': tenantId,
      'integration': integrationId,
      'id': id,
      ...values,
    });
  }

  @override
  Future<void> delete(String table, String tenantId, String id) async {
    calls.add({'table': table, 'tenant': tenantId, 'id': id});
  }
}

void main() {
  Future<FakeRepository> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = FakeRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExternalApiPanel(tenantId: 'tenant-a', repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ventas'));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets(
    'write execution validates JSON, requires confirmation, and displays actual error',
    (tester) async {
      final repo = await open(tester);
      await tester.tap(find.byTooltip('Ejecutar recurso'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Parámetros JSON (objeto)'),
        '[]',
      );
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('JSON inválido'), findsOneWidget);
      expect(repo.calls, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextField, 'Parámetros JSON (objeto)'),
        '{"id":5}',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Cuerpo JSON (opcional)'),
        '{"name":"Ana"}',
      );
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.text('Confirmar ejecución'), findsOneWidget);
      expect(repo.calls, isEmpty);
      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();
      expect(repo.calls.single['tenant_id'], 'tenant-a');
      expect(repo.calls.single['query'], {'id': 5});
      expect(repo.calls.single['body'], {'name': 'Ana'});
      expect(find.text('Resultado HTTP 422 · Error'), findsOneWidget);
      expect(find.textContaining('rechazado'), findsOneWidget);
      expect(find.textContaining('No existe result.data.'), findsOneWidget);
    },
  );

  testWidgets('new resource automation opt-ins default off', (tester) async {
    final repo = await open(tester);
    await tester.tap(find.text('Añadir recurso'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre del recurso'),
      'Clientes',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Ruta relativa (ej. /clientes)'),
      '/clients',
    );
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(repo.calls.single['tenant'], 'tenant-a');
    expect(repo.calls.single['enabled_for_automation'], false);
    expect(repo.calls.single['allow_automation_writes'], false);
  });

  testWidgets('deletion requires explicit confirmation', (tester) async {
    final repo = await open(tester);
    await tester.tap(find.byTooltip('Eliminar recurso'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    await tester.tap(find.byTooltip('Eliminar recurso'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();
    expect(repo.calls.single['tenant'], 'tenant-a');
    expect(repo.calls.single['id'], 'r1');
  });

  testWidgets(
    'editing keeps the secret field blank and scopes save to tenant',
    (tester) async {
      final repo = await open(tester);
      await tester.tap(find.text('Editar API'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Deja las credenciales vacías'),
        findsOneWidget,
      );
      final token = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Token'),
      );
      expect(token.controller!.text, isEmpty);
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(repo.calls.single['tenant_id'], 'tenant-a');
      expect(repo.calls.single['integration_id'], 'api');
      expect(repo.calls.single['auth_config'], {'token': ''});
    },
  );
}
