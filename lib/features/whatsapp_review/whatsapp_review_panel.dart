import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WhatsAppReviewRepository {
  WhatsAppReviewRepository(this.client);
  final SupabaseClient client;

  Future<Map<String, dynamic>> call(String tenantId, String action) async {
    final response = await client.functions.invoke(
      'send-whatsapp-review',
      body: {'tenant_id': tenantId, 'action': action},
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    if (data['error'] != null) {
      throw FunctionException(status: response.status, details: data);
    }
    return data;
  }
}

class WhatsAppReviewPanel extends StatefulWidget {
  const WhatsAppReviewPanel({
    super.key,
    required this.tenantId,
    this.repository,
  });
  final String tenantId;
  final WhatsAppReviewRepository? repository;

  @override
  State<WhatsAppReviewPanel> createState() => _WhatsAppReviewPanelState();
}

class _WhatsAppReviewPanelState extends State<WhatsAppReviewPanel> {
  late final _repository =
      widget.repository ?? WhatsAppReviewRepository(Supabase.instance.client);
  Map<String, dynamic>? _config;
  String? _error;
  String? _messageId;
  bool _busy = false;
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _failure(Object error) {
    if (error is FormatException) return error.message;
    if (error is FunctionException) {
      final details = error.details;
      if (details is Map && details['error'] is String) {
        return details['error'] as String;
      }
      return error.reasonPhrase ?? 'No se pudo completar la solicitud.';
    }
    return 'No se pudo contactar con el servidor. Revisa la conexión y la función de Supabase.';
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _config = null;
      _messageId = null;
      _confirmed = false;
    });
    try {
      final config = await _repository.call(widget.tenantId, 'status');
      if (!mounted) return;
      if (config['phone_number_id'] is! String ||
          config['recipient'] is! String ||
          config['template'] is! String ||
          config['language'] is! String) {
        throw const FormatException('Respuesta de configuración no válida.');
      }
      setState(() => _config = config);
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy || !_confirmed || _config == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _messageId = null;
    });
    try {
      final result = await _repository.call(widget.tenantId, 'send');
      if (result['provider_message_id'] is! String ||
          (result['provider_message_id'] as String).isEmpty ||
          result['status'] != 'accepted') {
        throw const FormatException('Respuesta de envío no válida.');
      }
      if (mounted) {
        setState(() {
          _messageId = result['provider_message_id'] as String;
          _confirmed = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Prueba real para revisión de Meta',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'Envía una plantilla real desde ITONE usando exclusivamente el número '
          'de prueba y el destinatario configurados en el servidor. '
          'No cambia la conexión de producción ni activa los flujos.',
        ),
        const SizedBox(height: 12),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_config case final config?) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    'Phone Number ID de prueba: ${config['phone_number_id']}',
                  ),
                  SelectableText(
                    'Destinatario autorizado: +${config['recipient']}',
                  ),
                  SelectableText('Plantilla: ${config['template']}'),
                  Text('Idioma: ${config['language']}'),
                  const SizedBox(height: 12),
                  const Text(
                    'Datos ficticios del pedido',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'Nombre: John Doe\nPedido: 123456\nFecha: Nov 6, 2026',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Meta renderiza el contenido de su plantilla de prueba. '
                    'El token nunca se muestra aquí.',
                  ),
                ],
              ),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: _busy
                ? null
                : (value) => setState(() => _confirmed = value == true),
            title: const Text(
              'Confirmo que este destinatario de prueba está autorizado y puedo revisar su WhatsApp.',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _busy || !_confirmed ? null : _send,
              icon: const Icon(Icons.send),
              label: const Text('Enviar plantilla real de prueba'),
            ),
          ),
        ],
        if (_messageId != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Meta aceptó el mensaje',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SelectableText('ID: $_messageId'),
                  const Text(
                    'Aceptado no significa entregado. Muestra el nuevo mensaje '
                    'en WhatsApp para completar la evidencia de recepción.',
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          'Máximo un intento por minuto y 20 en 24 horas. '
          'Si la respuesta falla, comprueba WhatsApp antes de reintentar. '
          'Estas pruebas no se añaden a la bandeja de conversaciones de producción.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Actualizar configuración de prueba'),
          ),
        ),
      ],
    ),
  );
}
