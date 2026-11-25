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

  Future<void> _load() async {
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
      if (mounted) setState(() => _bytes = bytes);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FunctionException && error.details is Map
              ? (error.details as Map)['error']?.toString() ??
                    'No se pudo cargar la imagen.'
              : 'No se pudo cargar la imagen. Intenta de nuevo.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _loading ? null : _load,
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.image_outlined),
          label: Text(
            _loading
                ? 'Cargando imagen…'
                : _error == null
                ? 'Ver imagen'
                : 'Reintentar imagen',
          ),
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
