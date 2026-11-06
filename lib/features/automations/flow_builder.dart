import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'flow_graph.dart';
import 'flow_repository.dart';

class FlowBuilder extends StatefulWidget {
  const FlowBuilder({
    super.key,
    required this.tenantId,
    required this.canEdit,
    this.repository,
  });
  final String tenantId;
  final bool canEdit;
  final FlowRepository? repository;
  @override
  State<FlowBuilder> createState() => _FlowBuilderState();
}

class _FlowBuilderState extends State<FlowBuilder> {
  late final _repository =
      widget.repository ?? FlowRepository(Supabase.instance.client);
  final _name = TextEditingController(text: 'Nuevo flujo');
  final _transform = TransformationController();
  FlowGraph _graph = FlowGraph.blank();
  List<SavedFlow> _flows = [];
  SavedFlow? _saved;
  String? _selected;
  ({String node, String port})? _connecting;
  String? _error;
  String? _notice;
  List<String> _validation = [];
  bool _busy = true;
  bool _dirty = false;
  int _counter = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _transform.dispose();
    super.dispose();
  }

  String _failure(Object error) =>
      error is PostgrestException ? error.message : '$error';
  void _changed() {
    _dirty = true;
    _validation = [];
    _notice = null;
    _error = null;
  }

  void _select(SavedFlow flow) {
    _saved = flow;
    _name.text = flow.name;
    _graph = flow.graph.copy();
    _dirty = false;
    _selected = null;
    _connecting = null;
    _validation = [];
    _transform.value = Matrix4.identity();
    _notice = null;
    _error = null;
  }

  Future<bool> _discard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cambios sin guardar'),
            content: const Text(
              'Esta acción descartará los cambios del lienzo. ¿Continuar?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Descartar cambios'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final flows = await _repository.list(widget.tenantId);
      if (!mounted) return;
      setState(() {
        _flows = flows;
        if (flows.isNotEmpty) {
          _select(
            flows.firstWhere(
              (flow) => flow.id == _saved?.id,
              orElse: () => flows.first,
            ),
          );
        } else {
          _saved = null;
          _graph = FlowGraph.blank();
          _name.text = 'Nuevo flujo';
          _dirty = false;
          _selected = null;
          _connecting = null;
          _validation = [];
          _notice = null;
          _transform.value = Matrix4.identity();
        }
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = 'No se pudieron cargar los flujos: ${_failure(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool publish = false}) async {
    if (_busy || !widget.canEdit) return;
    if (_name.text.trim().isEmpty || _name.text.trim().length > 100) {
      setState(() => _error = 'El nombre requiere entre 1 y 100 caracteres.');
      return;
    }
    if (publish) {
      final errors = _graph.validate();
      if (errors.isNotEmpty) {
        setState(() => _validation = errors);
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      var flow = _saved;
      if (flow == null || _dirty) {
        flow = await _repository.save(
          widget.tenantId,
          flow,
          _name.text,
          _graph.copy(),
        );
        if (!mounted) return;
        setState(() {
          _saved = flow;
          _dirty = false;
          _flows = [flow!, ..._flows.where((f) => f.id != flow!.id)];
        });
      }
      if (publish) {
        flow = await _repository.publish(widget.tenantId, flow);
        if (!mounted) return;
        setState(() {
          _saved = flow;
          _flows = [flow!, ..._flows.where((f) => f.id != flow!.id)];
        });
      }
      if (mounted) {
        setState(
          () => _notice = publish
              ? 'Versión ${flow!.publishedVersion} publicada solo para simulación. No envía WhatsApps.'
              : 'Borrador guardado en esta empresa.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo ${publish ? 'publicar' : 'guardar'}: ${_failure(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _new(bool template) async {
    if (!await _discard() || !mounted) return;
    setState(() {
      _saved = null;
      _graph = template ? FlowGraph.patientTemplate() : FlowGraph.blank();
      _name.text = template ? 'Atención EPS y particular' : 'Nuevo flujo';
      _selected = null;
      _connecting = null;
      _transform.value = Matrix4.identity();
      _changed();
    });
  }

  void _add(FlowKind kind) {
    if (_graph.nodes.length >= 60) {
      setState(() => _error = 'Máximo 60 bloques por flujo.');
      return;
    }
    String id;
    do {
      id = 'node_${++_counter}';
    } while (_graph.nodes.any((n) => n.id == id));
    final config = switch (kind) {
      FlowKind.text => {'text': 'Escribe tu mensaje'},
      FlowKind.question => {
        'text': '¿Qué necesitas?',
        'variable': 'respuesta_$_counter',
      },
      FlowKind.options => {
        'text': 'Elige una opción',
        'variable': 'opcion_$_counter',
        'options': 'EPS|Particular',
      },
      FlowKind.condition => {'variable': 'tipo', 'equals': 'EPS'},
      _ => <String, String>{},
    };
    final position = _transform.toScene(const Offset(150, 100));
    setState(() {
      _graph.nodes.add(
        FlowNode(
          id,
          kind,
          x: position.dx.clamp(0, 2600),
          y: position.dy.clamp(0, 1600),
          config: config,
        ),
      );
      _selected = id;
      _changed();
    });
  }

  void _connect(String target) {
    final source = _connecting!;
    if (source.node == target || _graph.node(target).kind == FlowKind.start) {
      setState(() => _error = 'Elige otro bloque que no sea Inicio.');
      return;
    }
    setState(() {
      _graph.edges.removeWhere(
        (e) => e.from == source.node && e.port == source.port,
      );
      _graph.edges.add(FlowEdge(source.node, source.port, target));
      _connecting = null;
      _changed();
    });
  }

  Future<void> _configure(FlowNode node) async {
    final fields = <String, String>{
      'title': 'Nombre del bloque',
      if ([
        FlowKind.text,
        FlowKind.question,
        FlowKind.options,
      ].contains(node.kind))
        'text': 'Mensaje',
      if ([
        FlowKind.question,
        FlowKind.options,
        FlowKind.condition,
      ].contains(node.kind))
        'variable': 'Variable',
      if (node.kind == FlowKind.options) 'options': 'Opciones separadas por |',
      if (node.kind == FlowKind.condition) 'equals': 'Es igual a',
    };
    final controllers = {
      for (final key in fields.keys)
        key: TextEditingController(text: node.config[key] ?? ''),
    };
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Configurar ${node.kind.label}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in fields.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: controllers[entry.key],
                      maxLength: 1000,
                      minLines: entry.key == 'text' ? 3 : 1,
                      maxLines: entry.key == 'text' ? 5 : 1,
                      decoration: InputDecoration(
                        labelText: entry.value,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                const Text(
                  'Variables: letras, números y _. Puedes usar {{variable}} en los mensajes. '
                  'No ingreses datos personales o de salud reales.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aplicar bloque'),
          ),
        ],
      ),
    );
    try {
      final confirmed = await Navigator.of(context).push(route) ?? false;
      await route.completed;
      if (confirmed && mounted) {
        setState(() {
          for (final entry in controllers.entries) {
            node.config[entry.key] = entry.value.text.trim();
          }
          _graph.edges.removeWhere(
            (e) => e.from == node.id && !node.ports.contains(e.port),
          );
          _connecting = null;
          _changed();
        });
      }
    } finally {
      for (final c in controllers.values) {
        c.dispose();
      }
    }
  }

  Future<void> _test(FlowGraph graph, String label) async {
    final errors = graph.validate();
    if (errors.isNotEmpty) {
      setState(() => _validation = errors);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 700,
          height: 720,
          child: FlowSimulation(graph: graph.copy(), label: label),
        ),
      ),
    );
  }

  Future<void> _versions() async {
    if (_saved == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final versions = await _repository.versions(widget.tenantId, _saved!.id);
      if (!mounted) return;
      setState(() => _busy = false);
      final selected = await showDialog<FlowVersion>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Versiones de simulación'),
          content: SizedBox(
            width: 440,
            child: versions.isEmpty
                ? const Text(
                    'Este flujo todavía no tiene versiones publicadas.',
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final v in versions)
                        ListTile(
                          title: Text('v${v.version} · ${v.name}'),
                          subtitle: const Text('Inmutable · Solo simulación'),
                          trailing: const Icon(Icons.play_arrow),
                          onTap: () => Navigator.pop(context, v),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      if (selected != null && mounted) {
        await _test(
          selected.graph,
          'Versión ${selected.version} · ${selected.name}',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = 'No se pudieron abrir las versiones: ${_failure(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected == null ? null : _graph.node(_selected!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Constructor de flujos',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Modo simulación · Publicar no activa WhatsApp ni consulta APIs. '
          'Usa solo datos ficticios. Guarda antes de salir: los cambios sin guardar se pierden.',
        ),
        if (!widget.canEdit)
          const Text(
            'Supervisor: consulta y prueba. Solo el administrador puede editar o publicar.',
          ),
        const SizedBox(height: 16),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_notice!),
          ),
        if (_validation.isNotEmpty)
          Card(
            color: const Color(0xFFFFEEEE),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Corrige el flujo antes de probar o publicar:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final error in _validation) Text('• $error'),
                ],
              ),
            ),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_flows.isNotEmpty)
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  key: UniqueKey(),
                  initialValue: _saved?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Flujo de esta empresa',
                    border: OutlineInputBorder(),
                  ),
                  items: _flows
                      .map(
                        (f) => DropdownMenuItem(
                          value: f.id,
                          child: Text(f.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (id) async {
                          if (id == null || id == _saved?.id) return;
                          if (!await _discard() || !mounted) {
                            if (mounted) setState(() {});
                            return;
                          }
                          setState(
                            () => _select(_flows.firstWhere((f) => f.id == id)),
                          );
                        },
                ),
              ),
            if (widget.canEdit) ...[
              OutlinedButton(
                onPressed: _busy ? null : () => _new(false),
                child: const Text('Nuevo flujo'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _new(true),
                child: const Text('Plantilla EPS / Particular'),
              ),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Guardar borrador'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _save(publish: true),
                child: const Text('Publicar para simulación'),
              ),
            ],
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      if (await _discard() && mounted) await _load();
                    },
              child: const Text('Recargar'),
            ),
            OutlinedButton(
              onPressed: _busy || _saved == null ? null : _versions,
              child: const Text('Versiones'),
            ),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _test(_graph, 'Borrador · ${_name.text}'),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Probar automatización'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          enabled: widget.canEdit && !_busy,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: 'Nombre del flujo',
            helperText:
                '${_dirty
                    ? 'Cambios sin guardar'
                    : _saved == null
                    ? 'Flujo local, todavía no guardado'
                    : 'Guardado · revisión ${_saved!.revision}'}'
                '${_saved?.publishedVersion == null ? '' : ' · versión publicada ${_saved!.publishedVersion} (simulación)'}',
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(_changed),
        ),
        const SizedBox(height: 12),
        if (widget.canEdit)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in FlowKind.values)
                ActionChip(
                  avatar: Icon(_icon(kind), size: 18),
                  label: Text('+ ${kind.label}'),
                  onPressed: _busy ? null : () => _add(kind),
                ),
            ],
          ),
        const SizedBox(height: 12),
        const Text(
          'Arrastra los bloques desde su icono. Desplaza o amplía el lienzo. '
          'Para conectar: pulsa una salida y luego el bloque destino; también puedes usar el panel de conexiones.',
        ),
        if (_connecting != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Conectando: ${_graph.node(_connecting!.node).title} → ${_connecting!.port}. Elige destino.',
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _connecting = null),
                child: const Text('Cancelar conexión'),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            IconButton(
              tooltip: 'Acercar lienzo',
              onPressed: () => _zoom(1.2),
              icon: const Icon(Icons.zoom_in),
            ),
            IconButton(
              tooltip: 'Alejar lienzo',
              onPressed: () => _zoom(1 / 1.2),
              icon: const Icon(Icons.zoom_out),
            ),
            TextButton(
              onPressed: () => _transform.value = Matrix4.identity(),
              child: const Text('Restablecer vista'),
            ),
          ],
        ),
        SizedBox(
          height: 540,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
              color: const Color(0xFFF2F5FB),
              child: InteractiveViewer(
                transformationController: _transform,
                constrained: false,
                minScale: .25,
                maxScale: 2,
                boundaryMargin: const EdgeInsets.all(200),
                child: SizedBox(
                  width: 2900,
                  height: 1800,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _Connections(_graph)),
                      ),
                      for (final node in _graph.nodes)
                        Positioned(
                          left: node.x,
                          top: node.y,
                          width: 240,
                          child: _nodeCard(node),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (selected != null) _inspector(selected),
      ],
    );
  }

  void _zoom(double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(.25, 2.0);
    final matrix = _transform.value.clone()
      ..scaleByDouble(next / current, next / current, 1, 1);
    _transform.value = matrix;
  }

  Widget _nodeCard(FlowNode node) => GestureDetector(
    key: ValueKey('node-${node.id}'),
    onTap: () {
      if (_connecting != null && widget.canEdit && !_busy) {
        _connect(node.id);
      } else {
        setState(() => _selected = node.id);
      }
    },
    child: Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: _selected == node.id ? Colors.blue : Colors.white,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: ValueKey('drag-${node.id}'),
              onPanUpdate: !widget.canEdit || _busy
                  ? null
                  : (details) {
                      final scale = _transform.value.getMaxScaleOnAxis();
                      setState(() {
                        node.x = (node.x + details.delta.dx / scale).clamp(
                          0,
                          2600,
                        );
                        node.y = (node.y + details.delta.dy / scale).clamp(
                          0,
                          1600,
                        );
                        _changed();
                      });
                    },
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: _color(node.kind),
                    child: Icon(_icon(node.kind), color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      node.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (widget.canEdit)
                    const Icon(Icons.drag_indicator, size: 18),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              node.kind.label,
              style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
            ),
            if (node.config['text'] != null)
              Text(
                node.config['text']!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            for (final port in node.ports)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: !widget.canEdit || _busy
                      ? null
                      : () => setState(() {
                          _selected = node.id;
                          _connecting = (node: node.id, port: port);
                        }),
                  child: Text('$port →'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
  Widget _inspector(FlowNode node) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Bloque seleccionado: ${node.title}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          Wrap(
            spacing: 12,
            children: [
              if (widget.canEdit)
                TextButton.icon(
                  onPressed: _busy ? null : () => _configure(node),
                  icon: const Icon(Icons.edit),
                  label: const Text('Configurar bloque'),
                ),
              if (widget.canEdit)
                TextButton.icon(
                  onPressed: _busy || node.kind == FlowKind.start
                      ? null
                      : () => setState(() {
                          _graph.nodes.remove(node);
                          _graph.edges.removeWhere(
                            (e) => e.from == node.id || e.to == node.id,
                          );
                          _selected = null;
                          _connecting = null;
                          _changed();
                        }),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Eliminar bloque'),
                ),
            ],
          ),
          for (final port in node.ports)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(
                        '${node.id}-$port-${_graph.edges.where((e) => e.from == node.id && e.port == port).firstOrNull?.to}',
                      ),
                      initialValue: _graph.edges
                          .where((e) => e.from == node.id && e.port == port)
                          .firstOrNull
                          ?.to,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Salida $port',
                        border: const OutlineInputBorder(),
                      ),
                      items: _graph.nodes
                          .where(
                            (n) => n.id != node.id && n.kind != FlowKind.start,
                          )
                          .map(
                            (n) => DropdownMenuItem(
                              value: n.id,
                              child: Text(
                                n.title,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: !widget.canEdit || _busy
                          ? null
                          : (id) {
                              if (id == null) return;
                              _connecting = (node: node.id, port: port);
                              _connect(id);
                            },
                    ),
                  ),
                  if (widget.canEdit)
                    IconButton(
                      tooltip: 'Desconectar $port',
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _graph.edges.removeWhere(
                                (e) => e.from == node.id && e.port == port,
                              );
                              _changed();
                            }),
                      icon: const Icon(Icons.link_off),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

IconData _icon(FlowKind kind) => switch (kind) {
  FlowKind.start => Icons.bolt,
  FlowKind.text => Icons.chat_bubble_outline,
  FlowKind.question => Icons.question_answer_outlined,
  FlowKind.options => Icons.alt_route,
  FlowKind.condition => Icons.call_split,
  FlowKind.api => Icons.api,
  FlowKind.review => Icons.fact_check_outlined,
  FlowKind.handoff => Icons.support_agent,
  FlowKind.end => Icons.flag_outlined,
};
Color _color(FlowKind kind) => switch (kind) {
  FlowKind.start => const Color(0xFF1765CE),
  FlowKind.api => const Color(0xFF8859CC),
  FlowKind.condition || FlowKind.options => const Color(0xFF309D80),
  FlowKind.review || FlowKind.handoff => const Color(0xFFCF8634),
  _ => const Color(0xFF5376BA),
};

class _Connections extends CustomPainter {
  _Connections(this.graph);
  final FlowGraph graph;
  @override
  void paint(Canvas canvas, Size size) {
    final dots = Paint()..color = const Color(0xFFD8DFED);
    for (double x = 20; x < size.width; x += 30) {
      for (double y = 20; y < size.height; y += 30) {
        canvas.drawCircle(Offset(x, y), 1, dots);
      }
    }
    final paint = Paint()
      ..color = const Color(0xFF8A9CBD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final e in graph.edges) {
      final from = graph.node(e.from);
      final to = graph.node(e.to);
      final a = Offset(from.x + 240, from.y + 55);
      final b = Offset(to.x, to.y + 35);
      final bend = math.max(60.0, (a.dx - b.dx).abs() / 2);
      canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..cubicTo(a.dx + bend, a.dy, b.dx - bend, b.dy, b.dx, b.dy),
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(b.dx - 8, b.dy - 5)
          ..lineTo(b.dx, b.dy)
          ..lineTo(b.dx - 8, b.dy + 5),
        paint,
      );
      final label = TextPainter(
        text: TextSpan(
          text: e.port,
          style: const TextStyle(color: Color(0xFF526783), fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 140);
      label.paint(canvas, Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - 18));
    }
  }

  @override
  bool shouldRepaint(covariant _Connections oldDelegate) => true;
}

class FlowSimulation extends StatefulWidget {
  const FlowSimulation({super.key, required this.graph, required this.label});
  final FlowGraph graph;
  final String label;
  @override
  State<FlowSimulation> createState() => _FlowSimulationState();
}

class _FlowSimulationState extends State<FlowSimulation> {
  final _input = TextEditingController();
  final _reason = TextEditingController();
  FlowRun? _run;
  String? _error;
  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void dispose() {
    _input.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _reset() {
    _error = null;
    _input.clear();
    _reason.clear();
    try {
      _run = FlowRun(widget.graph);
    } catch (error) {
      _run = null;
      _error = '$error';
    }
  }

  void _answer(String value) {
    try {
      _run!.answer(value, reason: _reason.text);
      _input.clear();
      _reason.clear();
      _error = null;
    } catch (error) {
      _error = '$error';
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Probar · ${widget.label}',
                  maxLines: 2,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Cerrar prueba',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const Text(
            'Solo datos ficticios. No hay IA, llamadas API, envíos ni asignaciones reales.',
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (run != null) ...[
                    for (final message in run.messages)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: message.incoming
                              ? const Color(0xFFD8F3DE)
                              : const Color(0xFFEAF2FF),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${message.incoming ? 'Entrada ficticia' : 'Bot simulado'}: ${message.text}',
                        ),
                      ),
                    if (!run.finished &&
                        !run.failed &&
                        [
                          FlowKind.question,
                          FlowKind.options,
                          FlowKind.api,
                          FlowKind.review,
                        ].contains(run.waiting.kind)) ...[
                      Text('Bloque actual: ${run.waiting.title}'),
                      if (run.waiting.kind == FlowKind.question) ...[
                        TextField(
                          controller: _input,
                          maxLength: 1000,
                          decoration: const InputDecoration(
                            labelText: 'Respuesta ficticia',
                          ),
                        ),
                        FilledButton(
                          onPressed: () => _answer(_input.text),
                          child: const Text('Responder'),
                        ),
                      ],
                      if (run.waiting.kind == FlowKind.review)
                        TextField(
                          controller: _reason,
                          maxLength: 1000,
                          decoration: const InputDecoration(
                            labelText: 'Motivo ficticio si deniegas',
                          ),
                        ),
                      if ([
                        FlowKind.api,
                        FlowKind.review,
                        FlowKind.options,
                      ].contains(run.waiting.kind))
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            for (final port in run.waiting.ports)
                              FilledButton(
                                onPressed: () => _answer(port),
                                child: Text(port),
                              ),
                          ],
                        ),
                    ],
                    if (run.finished)
                      const Text(
                        'Prueba finalizada · Sin cambios reales.',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    const Divider(height: 30),
                    const Text(
                      'Variables ficticias',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final entry in run.variables.entries)
                      Text('${entry.key}: ${entry.value}'),
                    const SizedBox(height: 12),
                    const Text(
                      'Recorrido ejecutado',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final (index, step) in run.trace.indexed)
                      Text('${index + 1}. $step'),
                  ],
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(_reset),
            child: const Text('Reiniciar prueba'),
          ),
        ],
      ),
    );
  }
}
