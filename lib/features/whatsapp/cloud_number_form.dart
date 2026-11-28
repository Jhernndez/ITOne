import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WhatsAppCloudNumberForm extends StatefulWidget {
  const WhatsAppCloudNumberForm({
    super.key,
    required this.tenantId,
    this.submit,
  });
  final String tenantId;
  final Future<Map<String, dynamic>> Function(Map<String, String> data)? submit;

  @override
  State<WhatsAppCloudNumberForm> createState() =>
      _WhatsAppCloudNumberFormState();
}

class _WhatsAppCloudNumberFormState extends State<WhatsAppCloudNumberForm> {
  final _waba = TextEditingController();
  final _phone = TextEditingController();
  final _token = TextEditingController();
  bool _saving = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _waba.dispose();
    _phone.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!RegExp(r'^\d{1,40}$').hasMatch(_waba.text.trim()) ||
        !RegExp(r'^\d{1,40}$').hasMatch(_phone.text.trim()) ||
        _token.text.trim().isEmpty) {
      setState(() {
        _error = true;
        _message = 'Completa los dos identificadores numéricos y el token.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final payload = {
        'tenant_id': widget.tenantId,
        'waba_id': _waba.text.trim(),
        'phone_number_id': _phone.text.trim(),
        'access_token': _token.text.trim(),
      };
      final submit = widget.submit;
      final data = submit != null
          ? await submit(payload)
          : Map<String, dynamic>.from(
              (await Supabase.instance.client.functions.invoke(
                    'connect-whatsapp-cloud',
                    body: payload,
                  )).data
                  as Map,
            );
      if (data['ok'] != true) {
        throw StateError(data['error'] ?? 'Meta no confirmó la conexión.');
      }
      _token.clear();
      if (mounted) {
        setState(() {
          _error = data['warning'] != null;
          _message = (data['warning'] ?? data['message']) as String;
        });
      }
    } on FunctionException catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = error.details is Map
              ? (error.details as Map)['error']?.toString() ??
                    'No se pudo conectar.'
              : 'No se pudo conectar: ${error.reasonPhrase}';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _message =
              'No se pudo conectar. Verifica los datos o contacta con soporte.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Agregar número Cloud API',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Usa credenciales de la aplicación Meta de ITONE. Al guardar se solicita la suscripción del webhook. No reemplaza un número con coexistencia. Los tokens temporales caducan.',
          ),
          TextField(
            controller: _waba,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: 'ID de cuenta de WhatsApp Business',
            ),
          ),
          TextField(
            controller: _phone,
            enabled: !_saving,
            decoration: const InputDecoration(labelText: 'Phone Number ID'),
          ),
          TextField(
            controller: _token,
            enabled: !_saving,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Token de acceso'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Validando...' : 'Validar y guardar número'),
          ),
          if (_message != null)
            Text(
              _message!,
              style: TextStyle(
                color: _error ? Theme.of(context).colorScheme.error : null,
              ),
            ),
        ],
      ),
    ),
  );
}
