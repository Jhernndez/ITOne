import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:itone/features/automations/flow_builder.dart';
import 'package:itone/features/automations/flow_graph.dart';
import 'package:itone/features/automations/flow_repository.dart';

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
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _Repository repository, {
    bool edit = true,
    bool mobile = false,
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
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FlowBuilder(
                tenantId: 'company-one',
                canEdit: edit,
                repository: repository,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    final f = find.text(text);
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

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
    'saves moved nodes and publishes immutable simulation versions in selected tenant',
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
      await tap(tester, 'Publicar para simulación');
      expect(repository.publications, 1);
      expect(
        find.textContaining('publicada solo para simulación'),
        findsOneWidget,
      );
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
      await tester.ensureVisible(find.text('Configurar bloque'));
      await tap(tester, 'Configurar bloque');
      await tester.enterText(
        find.widgetWithText(TextField, 'Mensaje'),
        'Mensaje del flujo diseñado',
      );
      await tap(tester, 'Aplicar bloque');
      final addedHandle = find.byKey(const ValueKey('drag-node_1'));
      await tester.ensureVisible(addedHandle);
      await tester.drag(addedHandle, const Offset(650, 250));
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
      expect(find.text('Publicar para simulación'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
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
    await tap(tester, 'Publicar para simulación');
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
    'mobile canvas, template and simulation render without overflow',
    (tester) async {
      final repository = _Repository();
      await open(tester, repository, mobile: true);
      await tap(tester, 'Plantilla EPS / Particular');
      await tap(tester, 'Probar automatización');
      await tap(tester, 'Particular');
      expect(
        find.text('Bot simulado: ¿Qué servicio particular necesitas?'),
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
