import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:itone/features/automations/flow_builder.dart';
import 'package:itone/features/automations/flow_graph.dart';
import 'package:itone/features/automations/flow_repository.dart';
import 'package:itone/features/automations/flow_canvas.dart';
import 'package:itone/features/automations/flow_backup_files.dart';

class _BackupFiles extends FlowBackupFiles {
  Map<String, dynamic>? backup;
  @override
  Future<bool> save(Map<String, dynamic> value) async {
    backup = value;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> open() async => backup;
}

class _Repository extends FlowRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  final List<SavedFlow> flows = [];
  final List<FlowVersion> snapshots = [];
  String? failure;
  String? tenant;
  int writes = 0;
  int publications = 0;
  bool protected = false;
  int demoInstalls = 0;
  @override
  Future<({String lookup, String reserve, String cancel})>
  installAppointmentDemo(String tenantId) async {
    demoInstalls++;
    tenant = tenantId;
    return (
      lookup: 'lookup-resource',
      reserve: 'reserve-resource',
      cancel: 'cancel-resource',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> apiResources(String tenantId) async {
    tenant = tenantId;
    return [
      {
        'id': '10000000-0000-0000-0000-000000000001',
        'name': 'Clientes',
        'http_method': 'GET',
      },
    ];
  }

  @override
  Future<List<SavedFlow>> list(String tenantId) async {
    if (failure != null) throw PostgrestException(message: failure!);
    tenant = tenantId;
    return flows.toList();
  }

  @override
  Future<SavedFlow> save(
    String tenantId,
    SavedFlow? previous,
    String name,
    FlowGraph graph,
  ) async {
    if (failure != null) throw PostgrestException(message: failure!);
    writes++;
    tenant = tenantId;
    final result = SavedFlow({
      'id': previous?.id ?? 'flow-1',
      'name': name,
      'draft': graph.copy().toJson(),
      'revision': (previous?.revision ?? 0) + 1,
      'published_version': previous?.publishedVersion,
    });
    flows.removeWhere((f) => f.id == result.id);
    flows.add(result);
    return result;
  }

  @override
  Future<SavedFlow> publish(String tenantId, SavedFlow flow) async {
    if (failure != null) throw PostgrestException(message: failure!);
    publications++;
    tenant = tenantId;
    final result = SavedFlow({
      'id': flow.id,
      'name': flow.name,
      'draft': flow.graph.toJson(),
      'revision': flow.revision + 1,
      'published_version': (flow.publishedVersion ?? 0) + 1,
    });
    snapshots.add(
      FlowVersion({
        'version': result.publishedVersion,
        'name': result.name,
        'graph': result.graph.copy().toJson(),
      }),
    );
    flows.removeWhere((f) => f.id == result.id);
    flows.add(result);
    return result;
  }

  @override
  Future<List<FlowVersion>> versions(String tenantId, String flowId) async =>
      snapshots.toList();

  @override
  Future<Map<String, dynamic>> exportBackup(
    String tenantId,
    String flowId,
  ) async => {
    'tenant_id': tenantId,
    'name': flows.firstWhere((flow) => flow.id == flowId).name,
    'draft': flows.firstWhere((flow) => flow.id == flowId).graph.toJson(),
  };

  @override
  Future<SavedFlow> restoreBackup(
    String tenantId,
    Map<String, dynamic> backup,
  ) async {
    final flow = SavedFlow({
      'id': 'restored',
      'name': backup['name'],
      'draft': backup['draft'],
      'revision': 1,
      'published_version': null,
    });
    flows.add(flow);
    return flow;
  }

  @override
  Future<void> deleteVersion(
    String tenantId,
    String flowId,
    int version,
  ) async {
    if (protected) throw const PostgrestException(message: 'Versión vinculada');
    snapshots.removeWhere((snapshot) => snapshot.version == version);
  }

  @override
  Future<void> deleteFlow(String tenantId, SavedFlow flow) async {
    if (protected) throw const PostgrestException(message: 'Flujo vinculado');
    flows.removeWhere((saved) => saved.id == flow.id);
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _Repository repository, {
    bool edit = true,
    bool mobile = false,
    FlowBackupFiles? backupFiles,
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(390, 844)
        : const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlowBuilder(
            tenantId: 'company-one',
            canEdit: edit,
            repository: repository,
            backupFiles: backupFiles,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    final f = find.text(text).evaluate().isNotEmpty
        ? find.text(text)
        : find.byTooltip(text);
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('installs an unactivated demo draft and allows simulation', (
    tester,
  ) async {
    final repository = _Repository();
    await open(tester, repository);
    await tap(tester, 'Crear demo de citas');
    await tap(tester, 'Crear demostración');
    expect(repository.demoInstalls, 1);
    expect(repository.tenant, 'company-one');
    expect(repository.publications, 0);
    await tap(tester, 'Guardar borrador');
    final graph = repository.flows.single.graph;
    expect(graph.node('search').config['resource_id'], 'lookup-resource');
    expect(graph.node('book').config['resource_id'], 'reserve-resource');
    expect(graph.validate(), isEmpty);
    await tap(tester, 'Probar automatización');
    expect(
      find.textContaining('Bot simulado: Esta es una prueba'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('exports, restores a new flow, and confirms protected deletion', (
    tester,
  ) async {
    final repository = _Repository();
    final files = _BackupFiles();
    await open(tester, repository, backupFiles: files);
    await tap(tester, 'Guardar borrador');
    await tap(tester, 'Publicar versión');
    await tap(tester, 'Exportar respaldo');
    expect(files.backup?['tenant_id'], 'company-one');
    await tap(tester, 'Restaurar respaldo');
    await tap(tester, 'Seleccionar archivo');
    expect(repository.flows.length, 2);
    expect(
      find.text('Flujo restaurado sin activar ningún bot.'),
      findsOneWidget,
    );
    repository.protected = true;
    await tap(tester, 'Eliminar flujo');
    await tester.tap(find.text('Eliminar flujo').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Flujo vinculado'), findsOneWidget);
    expect(repository.flows.length, 2);
    repository.protected = false;
    await tap(tester, 'Eliminar flujo');
    await tester.tap(find.text('Eliminar flujo').last);
    await tester.pumpAndSettle();
    expect(repository.flows.length, 1);
    await tap(tester, 'Versiones');
    await tester.tap(find.byTooltip('Eliminar versión 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar versión').last);
    await tester.pumpAndSettle();
    expect(repository.snapshots, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'API node selects a real tenant resource and persists JSON response mapping',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      await tap(tester, '+ Ejecutar API');
      final resource = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Recurso habilitado para automatización',
      );
      await tester.ensureVisible(resource);
      await tester.tap(resource);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GET · Clientes').last);
      await tester.pumpAndSettle();
      final query = find.widgetWithText(
        TextField,
        'Parámetros de consulta (JSON)',
      );
      await tester.ensureVisible(query);
      await tester.enterText(query, '{"telefono":"{{contact_phone}}"}');
      final path = find.widgetWithText(
        TextField,
        'Campo de respuesta opcional (body.estado)',
      );
      await tester.ensureVisible(path);
      await tester.enterText(path, 'body.estado');
      await tap(tester, 'Guardar borrador');
      final config = repository.flows.single.graph.node('node_1').config;
      expect(repository.tenant, 'company-one');
      expect(config['resource_id'], '10000000-0000-0000-0000-000000000001');
      expect(config['query'], '{"telefono":"{{contact_phone}}"}');
      expect(config['result_path'], 'body.estado');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'canvas fills the viewport and moves nodes beyond the old bounds at zoom',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      final canvasFinder = find.byType(FlowCanvas);
      final canvasRect = tester.getRect(canvasFinder);
      expect(canvasRect.height, greaterThan(850));
      expect(canvasRect.bottom, lessThanOrEqualTo(1100));
      expect(
        find.ancestor(of: canvasFinder, matching: find.byType(Scrollable)),
        findsNothing,
      );
      expect(find.text('Biblioteca de componentes'), findsOneWidget);
      expect(find.text('Configuración'), findsOneWidget);
      final canvas = tester.widget<FlowCanvas>(canvasFinder);
      canvas.controller.value = Matrix4.identity()
        ..translateByDouble(120, 60, 0, 1)
        ..scaleByDouble(.2, .2, 1, 1);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('drag-start')),
        const Offset(650, 200),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Guardar borrador');
      final moved = repository.flows.single.graph.node('start');
      expect(moved.x, greaterThan(2600));
      expect(moved.y, greaterThan(1000));
      await tap(tester, 'Ajustar flujo');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'searchable library supports dropping a block and inline edits persist',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      final search = find.widgetWithText(TextField, 'Buscar componentes');
      await tester.enterText(search, 'Enviar');
      await tester.pumpAndSettle();
      expect(find.text('+ Pregunta'), findsNothing);
      final canvasRect = tester.getRect(find.byType(FlowCanvas));
      final tile = find.text('+ Enviar texto');
      await tester.dragFrom(
        tester.getCenter(tile),
        canvasRect.topLeft + const Offset(350, 50) - tester.getCenter(tile),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('node-node_1')), findsOneWidget);
      final message = find.widgetWithText(TextField, 'Mensaje');
      await tester.ensureVisible(message);
      await tester.enterText(message, 'Edición directa');
      await tester.pumpAndSettle();
      await tap(tester, 'Guardar borrador');
      expect(
        repository.flows.single.graph.node('node_1').config['text'],
        'Edición directa',
      );
      expect(repository.flows.single.graph.node('node_1').x, closeTo(350, 2));
    },
  );
  testWidgets(
    'panning has no old canvas boundary and negative positions survive reload',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      final canvas = tester.widget<FlowCanvas>(find.byType(FlowCanvas));
      final rect = tester.getRect(find.byType(FlowCanvas));
      final focal = Offset(rect.width / 2, rect.height / 2);
      final before = canvas.controller.toScene(focal);
      await tap(tester, 'Alejar lienzo');
      final after = canvas.controller.toScene(focal);
      expect(after.dx, closeTo(before.dx, .01));
      expect(after.dy, closeTo(before.dy, .01));
      for (var i = 0; i < 6; i++) {
        await tester.dragFrom(
          rect.bottomRight - const Offset(80, 120),
          const Offset(600, 300),
        );
        await tester.pumpAndSettle();
      }
      expect(canvas.controller.value.entry(0, 3), greaterThan(2900));
      await tap(tester, '+ Enviar texto');
      await tap(tester, 'Guardar borrador');
      expect(repository.flows.single.graph.node('node_1').x, lessThan(-2600));
      expect(repository.flows.single.graph.node('node_1').y, lessThan(0));
      await tap(tester, 'Recargar');
      await tap(tester, 'Guardar borrador');
      expect(repository.flows.single.graph.node('node_1').x, lessThan(-2600));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'fullscreen control preserves edited draft while the shell is hidden',
    (tester) async {
      final repository = _Repository();
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool fullscreen = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              appBar: fullscreen ? null : AppBar(title: const Text('Cabecera')),
              body: Row(
                children: [
                  Visibility(
                    visible: !fullscreen,
                    child: const SizedBox(width: 200, child: Text('Menú')),
                  ),
                  Expanded(
                    child: FlowBuilder(
                      tenantId: 'company-one',
                      canEdit: true,
                      repository: repository,
                      fullscreen: fullscreen,
                      onToggleFullscreen: () =>
                          update(() => fullscreen = !fullscreen),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getSize(find.byType(FlowCanvas));
      await tester.enterText(
        find.widgetWithText(TextField, 'Nombre del flujo'),
        'Sin perder cambios',
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Pantalla completa');
      expect(find.text('Cabecera'), findsNothing);
      expect(find.text('Menú'), findsNothing);
      expect(find.text('Sin perder cambios'), findsOneWidget);
      final after = tester.getSize(find.byType(FlowCanvas));
      expect(after.width, greaterThan(before.width));
      expect(after.height, greaterThan(before.height));
      await tap(tester, 'Salir de pantalla completa');
      expect(find.text('Cabecera'), findsOneWidget);
      expect(find.text('Sin perder cambios'), findsOneWidget);
    },
  );

  testWidgets(
    'reload preserves the chosen flow and safely clears deleted drafts',
    (tester) async {
      final repository = _Repository();
      for (final (id, name) in [('one', 'Primero'), ('two', 'Segundo')]) {
        repository.flows.add(
          SavedFlow({
            'id': id,
            'name': name,
            'draft': FlowGraph.blank().toJson(),
            'revision': 1,
            'published_version': null,
          }),
        );
      }
      await open(tester, repository);
      final name = find.widgetWithText(TextField, 'Nombre del flujo');
      await tester.enterText(name, 'Cambio local');
      await tester.pumpAndSettle();
      final selector = find.byType(DropdownButtonFormField<String>);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Segundo').last);
      await tester.pumpAndSettle();
      await tap(tester, 'Cancelar');
      expect(
        tester.widget<DropdownButtonFormField<String>>(selector).initialValue,
        'one',
      );
      expect(find.text('Cambio local'), findsOneWidget);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Segundo').last);
      await tester.pumpAndSettle();
      await tap(tester, 'Descartar cambios');
      await tap(tester, 'Recargar');
      expect(
        tester.widget<DropdownButtonFormField<String>>(selector).initialValue,
        'two',
      );
      expect(find.text('Segundo'), findsNWidgets(2));
      await tap(tester, '+ Enviar texto');
      repository.flows.clear();
      await tap(tester, 'Recargar');
      await tap(tester, 'Descartar cambios');
      expect(find.text('Bloque seleccionado: Enviar texto'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saves moved nodes and publishes immutable versions without activating bots',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      final handle = find.byKey(const ValueKey('drag-start'));
      await tester.ensureVisible(handle);
      await tester.drag(handle, const Offset(70, 40));
      await tester.pumpAndSettle();
      await tap(tester, 'Guardar borrador');
      expect(repository.writes, 1);
      expect(repository.tenant, 'company-one');
      expect(repository.flows.single.graph.node('start').x, greaterThan(100));
      await tap(tester, 'Publicar versión');
      expect(repository.publications, 1);
      expect(find.textContaining('Actívala para un número'), findsOneWidget);
      await tap(tester, 'Versiones');
      await tap(tester, 'v1 · Nuevo flujo');
      expect(find.textContaining('Probar · Versión 1'), findsOneWidget);
      expect(
        find.text('Prueba finalizada · Sin cambios reales.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'configuration and explicit connection panel affect the tested draft',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository);
      await tap(tester, '+ Enviar texto');
      await tester.enterText(
        find.widgetWithText(TextField, 'Mensaje'),
        'Mensaje del flujo diseñado',
      );
      await tester.pumpAndSettle();
      final addedHandle = find.byKey(const ValueKey('drag-node_1'));
      await tester.ensureVisible(addedHandle);
      await tester.drag(addedHandle, const Offset(350, 260));
      await tester.pumpAndSettle();
      final output = find.byType(DropdownButtonFormField<String>).last;
      await tester.ensureVisible(output);
      await tester.tap(output);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finalizar').last);
      await tester.pumpAndSettle();
      // Connect Inicio to the inserted node by choosing the source port then the target card.
      await tester.ensureVisible(find.byKey(const ValueKey('node-start')));
      final source = find.descendant(
        of: find.byKey(const ValueKey('node-start')),
        matching: find.text('Siguiente →'),
      );
      await tester.tap(source);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('node-node_1')));
      await tester.pumpAndSettle();
      await tap(tester, 'Probar automatización');
      expect(
        find.text('Bot simulado: Mensaje del flujo diseñado'),
        findsOneWidget,
      );
      expect(
        find.text('Prueba finalizada · Sin cambios reales.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'supervisor can test but cannot edit, save, publish or add nodes',
    (tester) async {
      final repository = _Repository();
      repository.flows.add(
        SavedFlow({
          'id': 'one',
          'name': 'Solo lectura',
          'revision': 1,
          'published_version': null,
          'draft': FlowGraph.blank().toJson(),
        }),
      );
      await open(tester, repository, edit: false);
      expect(find.text('Guardar borrador'), findsNothing);
      expect(find.text('Publicar versión'), findsNothing);
      expect(find.text('Biblioteca de componentes'), findsNothing);
      await tap(tester, 'Probar automatización');
      expect(
        find.text('Prueba finalizada · Sin cambios reales.'),
        findsOneWidget,
      );
      expect(repository.writes, 0);
    },
  );
  testWidgets('validation blocks publication and backend errors are visible', (
    tester,
  ) async {
    final repository = _Repository();
    await open(tester, repository);
    await tap(tester, '+ Pregunta');
    await tap(tester, 'Publicar versión');
    expect(find.textContaining('Corrige el flujo'), findsOneWidget);
    expect(repository.publications, 0);
    repository.failure = 'El borrador cambio. Recarga antes de guardar.';
    await tap(tester, 'Guardar borrador');
    expect(
      find.textContaining('No se pudo guardar: El borrador cambio'),
      findsOneWidget,
    );
    expect(find.textContaining('Cambios sin guardar'), findsOneWidget);
  });
  testWidgets(
    'mobile canvas and simulation render without seeded examples or overflow',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository, mobile: true);
      expect(find.text('Plantilla EPS / Particular'), findsNothing);
      await tap(tester, 'Probar automatización');
      expect(
        find.text('Prueba finalizada · Sin cambios reales.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'simulation follows API error branch and requires agent denial reason',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlowSimulation(
              graph: FlowGraph.patientTemplate(),
              label: 'Prueba',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Particular');
      await tester.enterText(
        find.widgetWithText(TextField, 'Respuesta ficticia'),
        'Servicio ficticio',
      );
      await tap(tester, 'Responder');
      await tester.enterText(
        find.widgetWithText(TextField, 'Respuesta ficticia'),
        'No tengo',
      );
      await tap(tester, 'Responder');
      await tap(tester, 'Éxito');
      await tap(tester, 'Denegada');
      expect(find.textContaining('Escribe un motivo ficticio'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Motivo ficticio si deniegas'),
        'Motivo de prueba',
      );
      await tap(tester, 'Denegada');
      expect(find.textContaining('Motivo: Motivo de prueba'), findsOneWidget);
      expect(
        find.text('Prueba finalizada · Sin cambios reales.'),
        findsOneWidget,
      );
    },
  );
}
