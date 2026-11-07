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
  test(
    'rejects missing branches, unreachable blocks and malformed configuration',
    () {
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
      expect(cycle.validate(), isEmpty);
      expect(() => FlowRun(cycle), throwsStateError);
      final bad = FlowGraph.patientTemplate();
      bad.node('coverage').config['options'] = 'EPS|EPS';
      expect(bad.validate().join(), contains('únicas'));
      bad.node('coverage').config['variable'] = 'variable invalida';
      expect(bad.validate().join(), contains('variable no válida'));
    },
  );
  test(
    'question cycles can repeat and exit without an automatic infinite loop',
    () {
      final graph = FlowGraph(
        [
          FlowNode('s', FlowKind.start, x: -8000, y: -4000),
          FlowNode(
            'q',
            FlowKind.options,
            x: 12000,
            y: 18000,
            config: {
              'text': '¿Continuar?',
              'variable': 'opcion',
              'options': 'Repetir|Salir',
            },
          ),
          FlowNode('e', FlowKind.end),
        ],
        [
          const FlowEdge('s', 'Siguiente', 'q'),
          const FlowEdge('q', 'Repetir', 'q'),
          const FlowEdge('q', 'Salir', 'e'),
        ],
      );
      expect(graph.validate(), isEmpty);
      final run = FlowRun(graph);
      for (var i = 0; i < 120; i++) {
        run.answer('Repetir');
        expect(run.finished, isFalse);
        expect(run.waiting.id, 'q');
      }
      run.answer('Salir');
      expect(run.finished, isTrue);
      expect(graph.copy().node('s').x, -8000);
    },
  );
  test('long interactive cycles hit an explicit session budget', () {
    final graph = FlowGraph(
      [
        FlowNode('s', FlowKind.start),
        FlowNode(
          'q',
          FlowKind.question,
          config: {'text': 'Dato', 'variable': 'dato'},
        ),
      ],
      [
        const FlowEdge('s', 'Siguiente', 'q'),
        const FlowEdge('q', 'Siguiente', 'q'),
      ],
    );
    final run = FlowRun(graph);
    for (var i = 0; i < 998; i++) {
      run.answer('Prueba');
    }
    expect(() => run.answer('Otra'), throwsStateError);
    expect(run.failed, isTrue);
    expect(run.trace.length, lessThanOrEqualTo(1001));
  });
  test('automatic cycle reached after an answer fails without hanging or allowing a bypass', () {
    final graph = FlowGraph(
      [
        FlowNode('s', FlowKind.start),
        FlowNode(
          'q',
          FlowKind.question,
          config: {'text': 'Dato', 'variable': 'dato'},
        ),
        FlowNode('t', FlowKind.text, config: {'text': 'Ciclo'}),
      ],
      [
        const FlowEdge('s', 'Siguiente', 'q'),
        const FlowEdge('q', 'Siguiente', 't'),
        const FlowEdge('t', 'Siguiente', 't'),
      ],
    );
    final run = FlowRun(graph);
    expect(() => run.answer('Prueba'), throwsStateError);
    expect(run.failed, isTrue);
    expect(run.finished, isFalse);
    expect(run.messages.length, lessThanOrEqualTo(102));
    expect(() => run.answer('Otro intento'), throwsStateError);
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
