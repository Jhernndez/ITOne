import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'flow_graph.dart';

class FlowCanvas extends StatefulWidget {
  const FlowCanvas({
    super.key,
    required this.graph,
    required this.controller,
    required this.connections,
    required this.nodeBuilder,
  });

  final FlowGraph graph;
  final TransformationController controller;
  final CustomPainter connections;
  final Widget Function(FlowNode) nodeBuilder;

  @override
  State<FlowCanvas> createState() => _FlowCanvasState();
}

class _FlowCanvasState extends State<FlowCanvas> {
  Offset _anchor = Offset.zero;
  double _initialScale = 1;

  void _camera(Offset focal, Offset scene, double scale) {
    widget.controller.value = Matrix4.identity()
      ..translateByDouble(
        focal.dx - scene.dx * scale,
        focal.dy - scene.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: ColoredBox(
      color: const Color(0xFFF2F5FB),
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              final scale = widget.controller.value.entry(0, 0);
              _camera(
                event.localPosition,
                widget.controller.toScene(event.localPosition),
                (scale * math.exp(-event.scrollDelta.dy / 500)).clamp(.15, 2.0),
              );
            });
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (details) {
            _initialScale = widget.controller.value.entry(0, 0);
            _anchor = widget.controller.toScene(details.localFocalPoint);
          },
          onScaleUpdate: (details) => _camera(
            details.localFocalPoint,
            _anchor,
            (_initialScale * details.scale).clamp(.15, 2.0),
          ),
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final matrix = widget.controller.value;
              final scale = matrix.entry(0, 0);
              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _ViewportPainter(
                      matrix.clone(),
                      widget.connections,
                    ),
                  ),
                  for (final node in widget.graph.nodes)
                    Positioned(
                      left: MatrixUtils.transformPoint(
                        matrix,
                        Offset(node.x, node.y),
                      ).dx,
                      top: MatrixUtils.transformPoint(
                        matrix,
                        Offset(node.x, node.y),
                      ).dy,
                      width: 240 * scale,
                      child: FittedBox(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: 240,
                          child: widget.nodeBuilder(node),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _ViewportPainter extends CustomPainter {
  _ViewportPainter(this.matrix, this.connections);
  final Matrix4 matrix;
  final CustomPainter connections;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = matrix.entry(0, 0);
    final spacing = 30 * scale * (scale < .4 ? 4 : 1);
    final offset = MatrixUtils.transformPoint(matrix, Offset.zero);
    final dots = Paint()..color = const Color(0xFFD8DFED);
    for (double x = offset.dx % spacing; x < size.width; x += spacing) {
      for (double y = offset.dy % spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, dots);
      }
    }
    canvas.save();
    canvas.transform(matrix.storage);
    connections.paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ViewportPainter oldDelegate) => true;
}
