enum FlowKind {
  start('Inicio'),
  text('Enviar texto'),
  question('Pregunta'),
  options('Opciones'),
  condition('Condición'),
  api('API simulada'),
  review('Revisión de agente'),
  handoff('Transferir a humano'),
  end('Finalizar');

  const FlowKind(this.label);
  final String label;
}

class FlowNode {
  FlowNode(
    this.id,
    this.kind, {
    this.x = 80,
    this.y = 80,
    Map<String, String>? config,
  }) : config = config ?? {};
  final String id;
  final FlowKind kind;
  double x;
  double y;
  final Map<String, String> config;
  String get title => config['title']?.trim().isNotEmpty == true
      ? config['title']!
      : kind.label;
  List<String> get ports => switch (kind) {
    FlowKind.end || FlowKind.handoff => [],
    FlowKind.options =>
      (config['options'] ?? '')
          .split('|')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    FlowKind.condition => ['Sí', 'No'],
    FlowKind.api => ['Éxito', 'Error'],
    FlowKind.review => ['Aprobada', 'Denegada'],
    _ => ['Siguiente'],
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'x': x,
    'y': y,
    'config': config,
  };
  factory FlowNode.fromJson(Map<String, dynamic> json) => FlowNode(
    json['id'] as String,
    FlowKind.values.byName(json['kind'] as String),
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    config: Map<String, String>.from(json['config'] as Map),
  );
}

class FlowEdge {
  const FlowEdge(this.from, this.port, this.to);
  final String from;
  final String port;
  final String to;
  Map<String, dynamic> toJson() => {'from': from, 'port': port, 'to': to};
}

class FlowGraph {
  FlowGraph(this.nodes, this.edges);
  final List<FlowNode> nodes;
  final List<FlowEdge> edges;
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };
  factory FlowGraph.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Versión de flujo no compatible.');
    }
    return FlowGraph(
      (json['nodes'] as List)
          .map((n) => FlowNode.fromJson(Map<String, dynamic>.from(n as Map)))
          .toList(),
      (json['edges'] as List)
          .map(
            (e) => FlowEdge(
              e['from'] as String,
              e['port'] as String,
              e['to'] as String,
            ),
          )
          .toList(),
    );
  }
  FlowGraph copy() => FlowGraph.fromJson(toJson());
  FlowNode node(String id) => nodes.firstWhere((n) => n.id == id);
  List<String> validate() {
    final errors = <String>[];
    if (nodes.isEmpty || nodes.length > 60) {
      errors.add('El flujo debe tener entre 1 y 60 bloques.');
    }
    if (edges.length > 180) {
      errors.add('El flujo admite un máximo de 180 conexiones.');
    }
    if (nodes.map((n) => n.id).toSet().length != nodes.length) {
      errors.add('Hay identificadores duplicados.');
    }
    final starts = nodes.where((n) => n.kind == FlowKind.start).toList();
    if (starts.length != 1) errors.add('Debe existir exactamente un Inicio.');
    final ids = nodes.map((n) => n.id).toSet();
    for (final n in nodes) {
      if (!n.x.isFinite ||
          !n.y.isFinite ||
          n.x < 0 ||
          n.y < 0 ||
          n.x > 2600 ||
          n.y > 1600) {
        errors.add('${n.title}: posición fuera del lienzo.');
      }
      if ([
            FlowKind.text,
            FlowKind.question,
            FlowKind.options,
          ].contains(n.kind) &&
          (n.config['text'] ?? '').trim().isEmpty) {
        errors.add('${n.title}: falta el mensaje.');
      }
      if ([
            FlowKind.question,
            FlowKind.options,
            FlowKind.condition,
          ].contains(n.kind) &&
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$')
              .hasMatch(n.config['variable'] ?? '')) {
        errors.add('${n.title}: variable no válida.');
      }
      if (n.kind == FlowKind.options &&
          (n.ports.length < 2 ||
              n.ports.length > 6 ||
              n.ports.toSet().length != n.ports.length)) {
        errors.add(
          '${n.title}: usa entre 2 y 6 opciones únicas separadas por |.',
        );
      }
      if (n.kind == FlowKind.condition &&
          (n.config['equals'] ?? '').trim().isEmpty) {
        errors.add('${n.title}: falta el valor de comparación.');
      }
      if (n.config.values.any((v) => v.length > 1000)) {
        errors.add('${n.title}: máximo 1000 caracteres por campo.');
      }
      for (final port in n.ports) {
        if (edges.where((e) => e.from == n.id && e.port == port).length != 1) {
          errors.add('${n.title}: conecta la salida "$port" una sola vez.');
        }
      }
    }
    for (final e in edges) {
      if (!ids.contains(e.from) || !ids.contains(e.to)) {
        errors.add('Hay conexiones a bloques inexistentes.');
      } else if (!node(e.from).ports.contains(e.port) ||
          node(e.to).kind == FlowKind.start) {
        errors.add('Conexión no válida: ${e.port}.');
      }
    }
    final visited = <String>{};
    final stack = <String>{};
    bool cycle = false;
    void walk(String id) {
      if (stack.contains(id)) {
        cycle = true;
        return;
      }
      if (!ids.contains(id) || !visited.add(id)) return;
      stack.add(id);
      for (final e in edges.where((e) => e.from == id)) {
        walk(e.to);
      }
      stack.remove(id);
    }

    if (starts.length == 1) walk(starts.single.id);
    if (cycle) {
      errors.add(
        'Hay un ciclo. Conecta el recorrido sin volver a bloques anteriores.',
      );
    }
    if (visited.length != nodes.length) {
      errors.add('Hay bloques sin conexión desde Inicio.');
    }
    return errors.toSet().toList();
  }

  factory FlowGraph.blank() => FlowGraph(
    [
      FlowNode('start', FlowKind.start, x: 100, y: 180),
      FlowNode('end', FlowKind.end, x: 500, y: 180),
    ],
    [const FlowEdge('start', 'Siguiente', 'end')],
  );

  factory FlowGraph.patientTemplate() {
    FlowNode n(
      String id,
      FlowKind kind,
      double x,
      double y,
      Map<String, String> c,
    ) => FlowNode(id, kind, x: x, y: y, config: c);
    return FlowGraph(
      [
        n('start', FlowKind.start, 60, 400, {}),
        n('coverage', FlowKind.options, 360, 400, {
          'text': '¿Tu solicitud es por EPS o particular?',
          'variable': 'tipo',
          'options': 'EPS|Particular',
        }),
        n('eps', FlowKind.question, 680, 180, {
          'text': 'Indica tu EPS ficticia.',
          'variable': 'eps',
        }),
        n('eps_service', FlowKind.question, 1000, 180, {
          'text': '¿Qué servicio necesitas? Usa datos ficticios.',
          'variable': 'servicio',
        }),
        n('service', FlowKind.question, 680, 650, {
          'text': '¿Qué servicio particular necesitas?',
          'variable': 'servicio',
        }),
        n('exam', FlowKind.question, 1000, 650, {
          'text': '¿Tienes examen médico? Indica su nombre ficticio o escribe "No tengo".',
          'variable': 'examen',
        }),
        n('api', FlowKind.api, 1330, 400, {}),
        n('review', FlowKind.review, 1650, 180, {}),
        n('pending', FlowKind.text, 1970, 100, {
          'text': 'Revisión simulada completada. Solicitud pendiente, sin confirmar cita.',
        }),
        n('denied', FlowKind.text, 1970, 410, {
          'text': 'Solicitud denegada. Motivo: {{motivo_denegacion}}. Puedes continuar con atención humana.',
        }),
        n('error', FlowKind.text, 1650, 750, {
          'text': 'No fue posible consultar el sistema. Transferimos a un agente, sin confirmar la solicitud.',
        }),
        n('human', FlowKind.handoff, 2330, 650, {}),
        n('end', FlowKind.end, 2330, 100, {}),
      ],
      [
        const FlowEdge('start', 'Siguiente', 'coverage'),
        const FlowEdge('coverage', 'EPS', 'eps'),
        const FlowEdge('coverage', 'Particular', 'service'),
        const FlowEdge('eps', 'Siguiente', 'eps_service'),
        const FlowEdge('eps_service', 'Siguiente', 'api'),
        const FlowEdge('service', 'Siguiente', 'exam'),
        const FlowEdge('exam', 'Siguiente', 'api'),
        const FlowEdge('api', 'Éxito', 'review'),
        const FlowEdge('api', 'Error', 'error'),
        const FlowEdge('review', 'Aprobada', 'pending'),
        const FlowEdge('review', 'Denegada', 'denied'),
        const FlowEdge('pending', 'Siguiente', 'end'),
        const FlowEdge('denied', 'Siguiente', 'human'),
        const FlowEdge('error', 'Siguiente', 'human'),
      ],
    );
  }
}

class FlowRun {
  FlowRun(FlowGraph source) : graph = source.copy() {
    final errors = graph.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('\n'));
    current = graph.nodes.singleWhere((n) => n.kind == FlowKind.start).id;
    _advance();
  }
  final FlowGraph graph;
  final Map<String, String> variables = {};
  final List<({bool incoming, String text})> messages = [];
  final List<String> trace = [];
  late String current;
  bool finished = false;
  bool failed = false;
  FlowNode get waiting => graph.node(current);
  String render(String text) => text.replaceAllMapped(
    RegExp(r'\{\{([a-zA-Z][a-zA-Z0-9_]*)\}\}'),
    (m) {
      final value = variables[m[1]];
      if (value == null) {
        throw FormatException('Falta la variable ${m[1]} en ${waiting.title}.');
      }
      return value;
    },
  );
  void _next(String port) {
    final edge = graph.edges.singleWhere(
      (e) => e.from == current && e.port == port,
    );
    trace.add('${waiting.title} → $port');
    current = edge.to;
  }

  void _advance() {
    for (var i = 0; i < 100; i++) {
      final n = waiting;
      switch (n.kind) {
        case FlowKind.start:
          _next('Siguiente');
        case FlowKind.text:
          messages.add((incoming: false, text: render(n.config['text']!)));
          _next('Siguiente');
        case FlowKind.condition:
          final value = variables[n.config['variable']];
          if (value == null) {
            throw FormatException(
              'La condición requiere ${n.config['variable']} antes de continuar.',
            );
          }
          _next(
            value.toLowerCase() == n.config['equals']!.trim().toLowerCase()
                ? 'Sí'
                : 'No',
          );
        case FlowKind.end:
          finished = true;
          trace.add('Finalizado sin acciones reales.');
          return;
        case FlowKind.handoff:
          messages.add((
            incoming: false,
            text: 'Transferencia humana simulada. No se asignó ningún agente real.',
          ));
          finished = true;
          trace.add('Transferencia simulada.');
          return;
        case FlowKind.question || FlowKind.options:
          messages.add((incoming: false, text: render(n.config['text']!)));
          return;
        case FlowKind.api || FlowKind.review:
          trace.add('${n.title}: esperando resultado ficticio.');
          return;
      }
    }
    throw StateError('Se superó el límite de pasos de simulación.');
  }

  void answer(String value, {String reason = ''}) {
    if (finished) throw StateError('La prueba ya terminó.');
    if (failed) {
      throw StateError('Reinicia la prueba después del error de ejecución.');
    }
    final n = waiting;
    if (value.trim().isEmpty || value.length > 1000) {
      throw const FormatException(
        'Escribe entre 1 y 1000 caracteres ficticios.',
      );
    }
    String port;
    switch (n.kind) {
      case FlowKind.question:
        variables[n.config['variable']!] = value.trim();
        port = 'Siguiente';
      case FlowKind.options:
        if (!n.ports.contains(value)) {
          throw const FormatException('Selecciona una opción del bloque.');
        }
        variables[n.config['variable']!] = value;
        port = value;
      case FlowKind.api || FlowKind.review:
        if (!n.ports.contains(value)) {
          throw const FormatException('Resultado simulado no válido.');
        }
        if (n.kind == FlowKind.review && value == 'Denegada') {
          if (reason.trim().isEmpty || reason.length > 1000) {
            throw const FormatException(
              'Escribe un motivo ficticio de denegación.',
            );
          }
          variables['motivo_denegacion'] = reason.trim();
        }
        port = value;
      default:
        throw StateError('Este bloque no espera una respuesta.');
    }
    messages.add((
      incoming: true,
      text: n.kind == FlowKind.api || n.kind == FlowKind.review
          ? 'Resultado simulado: $value${reason.isEmpty ? '' : ' · $reason'}'
          : value,
    ));
    _next(port);
    try {
      _advance();
    } catch (_) {
      failed = true;
      rethrow;
    }
  }
}
