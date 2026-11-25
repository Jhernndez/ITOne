import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WhatsAppMessageImage extends StatefulWidget {
  const WhatsAppMessageImage({
    super.key,
    required this.tenantId,
    required this.messageId,
    this.loader,
  });
  final String tenantId;
  final String messageId;
  final Future<Uint8List> Function()? loader;

  @override
  State<WhatsAppMessageImage> createState() => _WhatsAppMessageImageState();
}

class _WhatsAppMessageImageState extends State<WhatsAppMessageImage> {
  Uint8List? _bytes;
  bool _loading = false;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant WhatsAppMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tenantId != widget.tenantId ||
        oldWidget.messageId != widget.messageId) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      Uint8List bytes;
      if (widget.loader != null) {
        bytes = await widget.loader!();
      } else {
        final response = await Supabase.instance.client.functions.invoke(
          'whatsapp-message-image',
          body: {'tenant_id': widget.tenantId, 'message_id': widget.messageId},
        );
        final data = response.data;
        if (data is! Map || data['base64'] is! String) {
          throw const FormatException('Respuesta de imagen no válida.');
        }
        bytes = base64Decode(data['base64'] as String);
      }
      if (mounted && request == _request) setState(() => _bytes = bytes);
    } catch (error) {
      if (mounted && request == _request) {
        setState(
          () => _error = error is FunctionException && error.details is Map
              ? (error.details as Map)['error']?.toString() ??
                    'No se pudo cargar la imagen.'
              : 'No se pudo cargar la imagen. Intenta de nuevo.',
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Widget _image() => Image.memory(
    _bytes!,
    width: 260,
    height: 200,
    fit: BoxFit.contain,
    errorBuilder: (_, _, _) =>
        const Text('El archivo no se pudo interpretar como imagen.'),
  );

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Semantics(
        label: 'Ampliar imagen de WhatsApp',
        button: true,
        child: InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: InteractiveViewer(
                      child: Image.memory(
                        _bytes!,
                        errorBuilder: (_, _, _) =>
                            const Text('No se pudo mostrar la imagen.'),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ),
          ),
          child: _image(),
        ),
      );
    }
    if (_loading) {
      return const SizedBox(
        width: 260,
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 8),
              Text('Cargando imagen…'),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Reintentar imagen'),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
