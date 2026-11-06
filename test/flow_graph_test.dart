import 'package:flutter_test/flutter_test.dart';
import 'package:itone/features/automations/flow_graph.dart';

void main() {
  test(
    'accepts 60 connected blocks and enforces size and connection limits',
    () {
      final graph = FlowGraph(
        List.generate(
          60,
          (i) => FlowNode(
            'n$i',
            i == 0
                ? FlowKind.start
                : i == 59
                ? FlowKind.end
                : FlowKind.text,
            config: {'text': 'Mensaje ficticio'},
          ),
        ),
        List.generate(59, (i) => FlowEdge('n$i', 'Siguiente', 'n${i + 1}')),
      );
      expect(graph.validate(), isEmpty);
      expect(FlowRun(graph).finished, isTrue);
      graph.nodes.add(FlowNode('excess', FlowKind.end));
      expect(graph.validate().join(), contains('60 bloques'));
      graph.edges.addAll(List.filled(122, graph.edges.first));
      expect(graph.validate().join(), contains('180 conexiones'));
    },
  );
  test('template round trips and runs the actual EPS success branch', () {
    final graph = FlowGraph.patientTemplate();
    expect(graph.validate(), isEmpty);
    final copy = FlowGraph.fromJson(graph.toJson());
    expect(copy.toJson(), graph.toJson());
    final run = FlowRun(copy);
    expect(run.waiting.id, 'coverage');
    run.answer('EPS');
    expect(run.waiting.id, 'eps');
    run.answer('EPS ficticia');
    run.answer('Servicio de prueba');
    expect(run.waiting.kind, FlowKind.api);
    run.answer('Éxito');
    expect(run.waiting.kind, FlowKind.review);
    run.answer('Aprobada');
    expect(run.finished, isTrue);
    expect(run.variables['eps'], 'EPS ficticia');
    expect(run.messages.last.text, contains('sin confirmar cita'));
    expect(run.trace.join(), isNot(contains('examen')));
  });
  test('particular denial requires reason, interpolates it, and transfers', () {
    final run = FlowRun(FlowGraph.patientTemplate());
    run.answer('Particular');
    run.answer('Servicio ficticio');
    run.answer('No tengo');
    run.answer('Éxito');
    expect(() => run.answer('Denegada'), throwsFormatException);
    expect(run.waiting.kind, FlowKind.review);
    run.answer('Denegada', reason: 'Ejemplo de motivo');
    expect(run.finished, isTrue);
    expect(
      run.messages.any((m) => m.text.contains('Motivo: Ejemplo de motivo')),
      isTrue,
    );
    expect(run.messages.last.text, contains('No se asignó ningún agente real'));
  });
  test(
    'API error follows the configured connection without confirming anything',
    () {
      final run = FlowRun(FlowGraph.patientTemplate());
      run.answer('EPS');
      run.answer('EPS ficticia');
      run.answer('Servicio');
      run.answer('Error');
      expect(run.finished, isTrue);
      expect(run.trace.join(), contains('API simulada → Error'));
      expect(
        run.messages.any((m) => m.text.contains('sin confirmar la solicitud')),
        isTrue,
      );
      expect(run.trace.join(), isNot(contains('Revisión de agente')));
    },
  );
  test('edits change execution, snapshots do not change, conditions use stored variables', () {
    final graph = FlowGraph(
      [
        FlowNode('s', FlowKind.start),
        FlowNode(
          'q',
          FlowKind.question,
          config: {'text': 'Tipo', 'variable': 'tipo'},
        ),
        FlowNode(
          'c',
          FlowKind.condition,
          config: {'variable': 'tipo', 'equals': 'EPS'},
        ),
        FlowNode('yes', FlowKind.text, config: {'text': 'Elegiste {{tipo}}'}),
        FlowNode('no', FlowKind.handoff),
        FlowNode('e', FlowKind.end),
      ],
      [
        const FlowEdge('s', 'Siguiente', 'q'),
        const FlowEdge('q', 'Siguiente', 'c'),
        const FlowEdge('c', 'Sí', 'yes'),
        const FlowEdge('c', 'No', 'no'),
        const FlowEdge('yes', 'Siguiente', 'e'),
      ],
    );
    expect(graph.validate(), isEmpty);
    final run = FlowRun(graph);
    graph.node('yes').config['text'] = 'Mensaje cambiado';
    run.answer('eps');
    expect(run.messages.last.text, 'Elegiste eps');
    final second = FlowRun(graph)..answer('particular');
    expect(
      second.messages.last.text,
      contains('Transferencia humana simulada'),
    );
    final third = FlowRun(graph)..answer('EPS');
    expect(third.messages.last.text, 'Mensaje cambiado');
  });
  test('rejects missing branches, unreachable blocks, cycles and malformed configuration', () {
    final missing = FlowGraph.patientTemplate()..edges.removeLast();
    expect(missing.validate(), isNotEmpty);
    final orphan = FlowGraph.blank()
      ..nodes.add(FlowNode('orphan', FlowKind.end));
    expect(orphan.validate().join(), contains('sin conexión'));
    final cycle = FlowGraph(
      [
        FlowNode('s', FlowKind.start),
        FlowNode('a', FlowKind.text, config: {'text': 'hola'}),
      ],
      [
        const FlowEdge('s', 'Siguiente', 'a'),
        const FlowEdge('a', 'Siguiente', 'a'),
      ],
    );
    expect(cycle.validate().join(), contains('ciclo'));
    expect(() => FlowRun(cycle), throwsFormatException);
    final bad = FlowGraph.patientTemplate();
    bad.node('coverage').config['options'] = 'EPS|EPS';
    expect(bad.validate().join(), contains('únicas'));
    bad.node('coverage').config['variable'] = 'variable invalida';
    expect(bad.validate().join(), contains('variable no válida'));
  });
  test(
    'unknown placeholders fail explicitly instead of inventing missing data',
    () {
      final graph = FlowGraph(
        [
          FlowNode('s', FlowKind.start),
          FlowNode('t', FlowKind.text, config: {'text': '{{desconocido}}'}),
          FlowNode('e', FlowKind.end),
        ],
        [
          const FlowEdge('s', 'Siguiente', 't'),
          const FlowEdge('t', 'Siguiente', 'e'),
        ],
      );
      expect(() => FlowRun(graph), throwsFormatException);
    },
  );
  test(
    'runtime failures cannot be bypassed by answering an undisplayed question',
    () {
      final graph = FlowGraph.patientTemplate();
      graph.node('eps').config['text'] = 'Mensaje {{inexistente}}';
      final run = FlowRun(graph);
      expect(() => run.answer('EPS'), throwsFormatException);
      expect(run.failed, isTrue);
      expect(run.finished, isFalse);
      expect(() => run.answer('Continuar'), throwsStateError);
    },
  );
}
