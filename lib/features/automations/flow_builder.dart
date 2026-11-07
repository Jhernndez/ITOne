import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'flow_graph.dart';
import 'flow_repository.dart';
import 'flow_canvas.dart';

class FlowBuilder extends StatefulWidget {
  const FlowBuilder({
    super.key,
    required this.tenantId,
    required this.canEdit,
    this.repository,
    this.fullscreen = false,
    this.onToggleFullscreen,
  });
  final String tenantId;
  final bool canEdit;
  final FlowRepository? repository;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;
  @override
  State<FlowBuilder> createState() => _FlowBuilderState();
}

class _FlowBuilderState extends State<FlowBuilder> {
  late final _repository =
      widget.repository ?? FlowRepository(Supabase.instance.client);
  final _name = TextEditingController(text: 'Nuevo flujo');
  final _transform = TransformationController();
  final _canvasKey = GlobalKey();
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
  final _componentSearch = TextEditingController();
  bool _libraryOpen = false;
  final Map<String, GlobalKey> _nodeKeys = {};
  final Map<String, Size> _nodeSizes = {};
  Offset? _dragPoint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _componentSearch.dispose();
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit();
    });
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit();
    });
  }

  void _add(FlowKind kind, {Offset? at}) {
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
    final position = _transform.toScene(at ?? const Offset(80, 60));
    if (!position.dx.isFinite ||
        !position.dy.isFinite ||
        position.dx.abs() > 1e9 ||
        position.dy.abs() > 1e9) {
      setState(
        () =>
            _error = 'Vuelve a una zona dentro del rango numérico del lienzo.',
      );
      return;
    }
    setState(() {
      _graph.nodes.add(
        FlowNode(id, kind, x: position.dx, y: position.dy, config: config),
      );
      _selected = id;
      _changed();
    });
  }

  void _connect(String target) {
    final source = _connecting!;
    if (_graph.node(target).kind == FlowKind.start) {
      setState(() => _error = 'Conecta a un bloque distinto de Inicio.');
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

  void _configure(FlowNode node, Map<String, String> values) {
    setState(() {
      node.config.addAll(values);
      _graph.edges.removeWhere(
        (e) => e.from == node.id && !node.ports.contains(e.port),
      );
      _connecting = null;
      _changed();
    });
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
    final compact = MediaQuery.sizeOf(context).width < 1000;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      bool changed = false;
      for (final node in _graph.nodes) {
        final size = _nodeKeys[node.id]?.currentContext?.size;
        if (size != null && _nodeSizes[node.id] != size) {
          _nodeSizes[node.id] = size;
          changed = true;
        }
      }
      if (changed) setState(() {});
    });
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Constructor · Solo simulación',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              if (widget.canEdit)
                _action(
                  'Guardar borrador',
                  Icons.save_outlined,
                  _busy ? null : _save,
                  compact,
                ),
              _action(
                'Probar automatización',
                Icons.play_arrow,
                _busy ? null : () => _test(_graph, 'Borrador · ${_name.text}'),
                compact,
              ),
              if (widget.canEdit)
                _action(
                  'Publicar para simulación',
                  Icons.rocket_launch_outlined,
                  _busy ? null : () => _save(publish: true),
                  compact,
                ),
              const Tooltip(
                message:
                    'Publicar no activa WhatsApp ni consulta APIs. Usa datos ficticios. '
                    'Guarda antes de salir. Supervisor: solo consulta y prueba.',
                child: Icon(Icons.info_outline, size: 20),
              ),
              if (widget.onToggleFullscreen != null)
                IconButton(
                  tooltip: widget.fullscreen
                      ? 'Salir de pantalla completa'
                      : 'Pantalla completa',
                  onPressed: widget.onToggleFullscreen,
                  icon: Icon(
                    widget.fullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                  ),
                ),
            ],
          ),
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
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(
                child: Card(
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
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              spacing: 10,
              children: [
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _name,
                    enabled: widget.canEdit && !_busy,
                    maxLength: 100,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Nombre del flujo',
                      counterText: '',
                      helperText: _dirty
                          ? 'Cambios sin guardar'
                          : _saved == null
                          ? 'Todavía no guardado'
                          : 'Guardado · revisión ${_saved!.revision}',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(_changed),
                  ),
                ),
                if (_flows.isNotEmpty)
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      key: UniqueKey(),
                      initialValue: _saved?.id,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Flujo de esta empresa',
                        border: OutlineInputBorder(),
                      ),
                      items: _flows
                          .map(
                            (f) => DropdownMenuItem(
                              value: f.id,
                              child: Text(
                                f.name,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                                () => _select(
                                  _flows.firstWhere((f) => f.id == id),
                                ),
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
              ],
            ),
          ),
          const SizedBox(height: 6),
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
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 1100;
                final panel = Material(
                  elevation: 4,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const SizedBox(width: 12),
                          const Expanded(child: Text('Configuración')),
                          IconButton(
                            tooltip: 'Cerrar panel',
                            onPressed: selected == null
                                ? null
                                : () => setState(() => _selected = null),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: selected == null
                              ? const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Text(
                                    'Selecciona un bloque para editar su mensaje, variables y conexiones.',
                                  ),
                                )
                              : _inspector(selected),
                        ),
                      ),
                    ],
                  ),
                );
                final canvas = Stack(
                  children: [
                    Positioned.fill(
                      child: DragTarget<FlowKind>(
                        onWillAcceptWithDetails: (_) =>
                            widget.canEdit && !_busy,
                        onAcceptWithDetails: (details) {
                          final box =
                              _canvasKey.currentContext!.findRenderObject()
                                  as RenderBox;
                          _add(
                            details.data,
                            at: box.globalToLocal(details.offset),
                          );
                        },
                        builder: (context, candidates, rejected) => FlowCanvas(
                          key: _canvasKey,
                          graph: _graph,
                          controller: _transform,
                          connections: _Connections(_graph, Map.of(_nodeSizes)),
                          nodeBuilder: _nodeCard,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Material(
                        elevation: 2,
                        borderRadius: BorderRadius.circular(12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!wide && widget.canEdit)
                              IconButton(
                                tooltip: 'Biblioteca de componentes',
                                onPressed: () => setState(
                                  () => _libraryOpen = !_libraryOpen,
                                ),
                                icon: const Icon(Icons.widgets_outlined),
                              ),
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
                            IconButton(
                              tooltip: 'Ajustar flujo',
                              onPressed: _fit,
                              icon: const Icon(Icons.center_focus_strong),
                            ),
                            IconButton(
                              tooltip: 'Restablecer vista',
                              onPressed: () =>
                                  _transform.value = Matrix4.identity(),
                              icon: const Icon(Icons.restart_alt),
                            ),
                            const Tooltip(
                              message:
                                  'Arrastra el fondo para mover el lienzo. Rueda o pellizca para zoom. '
                                  'Arrastra la cabecera de un bloque para moverlo. Pulsa una salida y luego el destino para conectar.',
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.help_outline),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!wide && _libraryOpen && widget.canEdit)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 60,
                        width: 230,
                        child: _library(),
                      ),
                  ],
                );
                if (wide) {
                  return Row(
                    children: [
                      if (widget.canEdit)
                        SizedBox(width: 210, child: _library()),
                      Expanded(child: canvas),
                      SizedBox(width: 330, child: panel),
                    ],
                  );
                }
                if (selected == null) return canvas;
                return Column(
                  children: [
                    Expanded(child: canvas),
                    SizedBox(
                      height: math.min(260, constraints.maxHeight * .45),
                      child: panel,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(
    String label,
    IconData icon,
    VoidCallback? callback,
    bool compact,
  ) => compact
      ? IconButton(tooltip: label, onPressed: callback, icon: Icon(icon))
      : Padding(
          padding: const EdgeInsets.only(right: 6),
          child: OutlinedButton.icon(
            onPressed: callback,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );

  Widget _library() {
    const groups = {
      'Inicio': [FlowKind.start],
      'Mensajes': [FlowKind.text],
      'Preguntas y respuestas': [FlowKind.question, FlowKind.options],
      'Condiciones': [FlowKind.condition],
      'Conexiones API': [FlowKind.api],
      'Atención humana': [FlowKind.review, FlowKind.handoff],
      'Cierre': [FlowKind.end],
    };
    final matching = FlowKind.values
        .where(
          (kind) => kind.label.toLowerCase().contains(
            _componentSearch.text.toLowerCase(),
          ),
        )
        .toSet();
    return Material(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Biblioteca de componentes',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextField(
              controller: _componentSearch,
              decoration: const InputDecoration(
                hintText: 'Buscar componentes',
                isDense: true,
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                if (matching.isEmpty)
                  const ListTile(title: Text('Sin componentes')),
                for (final group in groups.entries)
                  if (group.value.any(matching.contains)) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
                      child: Text(
                        group.key,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    for (final kind in group.value.where(matching.contains))
                      Draggable<FlowKind>(
                        data: kind,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        maxSimultaneousDrags: _busy ? 0 : 1,
                        feedback: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(kind.label),
                          ),
                        ),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            _icon(kind),
                            color: _color(kind),
                            size: 20,
                          ),
                          title: Text(
                            '+ ${kind.label}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: _busy
                              ? null
                              : () {
                                  _add(kind);
                                  setState(() => _libraryOpen = false);
                                },
                        ),
                      ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _fit() {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _graph.nodes.isEmpty) return;
    final left = _graph.nodes.map((n) => n.x).reduce(math.min);
    final top = _graph.nodes.map((n) => n.y).reduce(math.min);
    final right = _graph.nodes.map((n) => n.x + 260).reduce(math.max);
    final bottom = _graph.nodes
        .map((n) => n.y + (_nodeSizes[n.id]?.height ?? 300))
        .reduce(math.max);
    final width = math.max(100.0, box.size.width - 48);
    final height = math.max(100.0, box.size.height - 90);
    final scale = math
        .min(width / (right - left), height / (bottom - top))
        .clamp(.15, 2.0);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        24 + (width - (right - left) * scale) / 2 - left * scale,
        24 + (height - (bottom - top) * scale) / 2 - top * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _zoom(double factor) {
    final current = _transform.value.entry(0, 0);
    final next = (current * factor).clamp(.15, 2.0);
    final size = _canvasKey.currentContext?.size;
    final focal = size == null ? Offset.zero : size.center(Offset.zero);
    final scene = _transform.toScene(focal);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        focal.dx - scene.dx * next,
        focal.dy - scene.dy * next,
        0,
        1,
      )
      ..scaleByDouble(next, next, 1, 1);
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
      key: _nodeKeys.putIfAbsent(node.id, GlobalKey.new),
      color: Color.alphaBlend(
        _color(node.kind).withValues(alpha: .08),
        Colors.white,
      ),
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
              onPanStart: !widget.canEdit || _busy
                  ? null
                  : (details) {
                      _dragPoint = details.globalPosition;
                    },
              onPanEnd: !widget.canEdit || _busy
                  ? null
                  : (_) => _dragPoint = null,
              onPanCancel: !widget.canEdit || _busy
                  ? null
                  : () => _dragPoint = null,
              onPanUpdate: !widget.canEdit || _busy
                  ? null
                  : (details) {
                      final scale = _transform.value.entry(0, 0);
                      final delta =
                          details.globalPosition -
                          (_dragPoint ?? details.globalPosition);
                      _dragPoint = details.globalPosition;
                      setState(() {
                        final x = node.x + delta.dx / scale;
                        final y = node.y + delta.dy / scale;
                        if (x.abs() > 1e9 || y.abs() > 1e9) {
                          _error = 'Se alcanzó el rango numérico del lienzo.';
                          return;
                        }
                        node.x = x;
                        node.y = y;
                        _changed();
                      });
                    },
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: _color(node.kind),
                    child: Icon(
                      _icon(node.kind),
                      color: Colors.white,
                      size: 19,
                    ),
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
                style: const TextStyle(fontSize: 12),
              ),
            for (final port in node.ports)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
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
          _NodeConfiguration(
            key: ObjectKey(node),
            node: node,
            enabled: widget.canEdit && !_busy,
            onChanged: (values) => _configure(node, values),
          ),
          const SizedBox(height: 12),
          const Text(
            'Salidas del componente',
            style: TextStyle(fontWeight: FontWeight.bold),
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
                          .where((n) => n.kind != FlowKind.start)
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
  FlowKind.start => const Color(0xFF23A95B),
  FlowKind.api => const Color(0xFF159DB5),
  FlowKind.question || FlowKind.options => const Color(0xFF8859CC),
  FlowKind.condition => const Color(0xFF309D80),
  FlowKind.review || FlowKind.handoff => const Color(0xFFCF8634),
  _ => const Color(0xFF5376BA),
};

class _Connections extends CustomPainter {
  _Connections(this.graph, this.sizes);
  final FlowGraph graph;
  final Map<String, Size> sizes;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF8A9CBD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final e in graph.edges) {
      final from = graph.node(e.from);
      final to = graph.node(e.to);
      final portIndex = from.ports.indexOf(e.port);
      final a = Offset(
        from.x + 240 * (portIndex + 1) / (from.ports.length + 1),
        from.y + (sizes[from.id]?.height ?? 160),
      );
      final b = Offset(to.x + 120, to.y);
      final bend = math.max(60.0, (a.dy - b.dy).abs() / 2);
      final path = Path()..moveTo(a.dx, a.dy);
      if (b.dy > a.dy && from.id != to.id) {
        path.cubicTo(a.dx, a.dy + bend, b.dx, b.dy - bend, b.dx, b.dy);
      } else {
        final side = math.max(from.x + 280, to.x + 280) + portIndex * 30;
        path
          ..cubicTo(a.dx, a.dy + 60, side, a.dy + 60, side, a.dy)
          ..lineTo(side, b.dy - 50)
          ..cubicTo(side, b.dy - 80, b.dx, b.dy - 80, b.dx, b.dy);
      }
      canvas.drawPath(path, paint);
      canvas.drawPath(
        Path()
          ..moveTo(b.dx - 5, b.dy - 8)
          ..lineTo(b.dx, b.dy)
          ..lineTo(b.dx + 5, b.dy - 8),
        paint,
      );
      final label = TextPainter(
        text: TextSpan(
          text: e.port,
          style: const TextStyle(color: Color(0xFF526783), fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 140);
      label.paint(canvas, Offset(a.dx + 8, a.dy + 8));
    }
  }

  @override
  bool shouldRepaint(covariant _Connections oldDelegate) => true;
}

class _NodeConfiguration extends StatefulWidget {
  const _NodeConfiguration({
    super.key,
    required this.node,
    required this.enabled,
    required this.onChanged,
  });
  final FlowNode node;
  final bool enabled;
  final ValueChanged<Map<String, String>> onChanged;

  @override
  State<_NodeConfiguration> createState() => _NodeConfigurationState();
}

class _NodeConfigurationState extends State<_NodeConfiguration> {
  late final fields = <String, String>{
    'title': 'Nombre del bloque',
    if ([
      FlowKind.text,
      FlowKind.question,
      FlowKind.options,
    ].contains(widget.node.kind))
      'text': 'Mensaje',
    if ([
      FlowKind.question,
      FlowKind.options,
      FlowKind.condition,
    ].contains(widget.node.kind))
      'variable': 'Variable',
    if (widget.node.kind == FlowKind.options)
      'options': 'Opciones separadas por |',
    if (widget.node.kind == FlowKind.condition) 'equals': 'Es igual a',
  };
  late final controllers = {
    for (final key in fields.keys)
      key: TextEditingController(text: widget.node.config[key] ?? ''),
  };

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final field in fields.entries)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            controller: controllers[field.key],
            enabled: widget.enabled,
            maxLength: 1000,
            minLines: field.key == 'text' ? 3 : 1,
            maxLines: field.key == 'text' ? 5 : 1,
            decoration: InputDecoration(
              labelText: field.value,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => widget.onChanged({
              for (final entry in controllers.entries)
                entry.key: entry.value.text.trim(),
            }),
          ),
        ),
      const Text(
        'Los cambios del bloque se aplican al borrador al escribir. '
        'Usa {{variable}} para insertar respuestas. Solo datos ficticios.',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );
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
