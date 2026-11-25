import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BotRepository {
  BotRepository(this.client);
  final SupabaseClient client;

  Future<Map<String, List<Map<String, dynamic>>>> load(String tenantId) async {
    final results = await Future.wait([
      client
          .from('whatsapp_accounts')
          .select('id,name,display_phone_number,status,onboarding_mode')
          .eq('tenant_id', tenantId),
      client
          .from('automation_flow_versions')
          .select('flow_id,version,name')
          .eq('tenant_id', tenantId)
          .order('version', ascending: false),
      client
          .from('whatsapp_bot_bindings')
          .select('account_id,flow_id,version,enabled')
          .eq('tenant_id', tenantId),
      client
          .from('whatsapp_bot_jobs')
          .select('id,error,finished_at')
          .eq('tenant_id', tenantId)
          .eq('status', 'failed')
          .order('finished_at', ascending: false)
          .limit(10),
    ]);
    return {
      for (var i = 0; i < results.length; i++)
        ['accounts', 'versions', 'bindings', 'failures'][i]: results[i],
    };
  }

  Future<void> configure(
    String tenantId,
    String accountId,
    Map<String, dynamic>? version,
    bool enabled,
  ) => client.rpc(
    'configure_whatsapp_bot',
    params: {
      'p_tenant_id': tenantId,
      'p_account_id': accountId,
      'p_flow_id': version?['flow_id'],
      'p_version': version?['version'],
      'p_enabled': enabled,
    },
  );
}

class BotSettingsPanel extends StatefulWidget {
  const BotSettingsPanel({super.key, required this.tenantId, this.repository});
  final String tenantId;
  final BotRepository? repository;
  @override
  State<BotSettingsPanel> createState() => _BotSettingsPanelState();
}

class _BotSettingsPanelState extends State<BotSettingsPanel> {
  late final _repository =
      widget.repository ?? BotRepository(Supabase.instance.client);
  Map<String, List<Map<String, dynamic>>>? _data;
  String? _account;
  String? _version;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _repository.load(widget.tenantId);
      if (mounted) {
        setState(() {
          _data = data;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No se pudo cargar la automatización: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _configure(bool enabled) async {
    if (_account == null) return;
    Map<String, dynamic>? version;
    for (final v in _data!['versions']!) {
      if ('${v['flow_id']}:${v['version']}' == _version) version = v;
    }
    if (enabled && version == null) return;
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Activar respuestas reales'),
          content: const Text(
            'Este número responderá automáticamente a nuevos mensajes. '
            'Las APIs habilitadas podrán ejecutarse. Prueba primero tu flujo. '
            'Responder manualmente pausa el bot hasta reactivarlo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Activar bot'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repository.configure(widget.tenantId, _account!, version, enabled);
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No se pudo actualizar el bot: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final binding = data?['bindings']
        ?.where((b) => b['account_id'] == _account)
        .firstOrNull;
    final enabled = binding?['enabled'] == true;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Respuestas automáticas',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Desactivadas por defecto. Publica y prueba un flujo en Automatizaciones; '
          'después selecciona el número y la versión aquí. No se procesan historiales importados.',
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (data != null) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('account-$_account'),
            initialValue: _account,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Número de tu empresa',
              border: OutlineInputBorder(),
            ),
            items: data['accounts']!
                .map(
                  (a) => DropdownMenuItem(
                    value: a['id'] as String,
                    child: Text(
                      '${a['name'] ?? 'WhatsApp'} ${a['display_phone_number'] ?? ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _account = value;
                    _version = null;
                  }),
          ),
          const SizedBox(height: 16),
          Text(
            enabled
                ? 'Bot activo · versión ${binding!['version']}'
                : 'Bot desactivado',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('version-$_version'),
            initialValue: _version,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Versión publicada',
              border: OutlineInputBorder(),
            ),
            items: data['versions']!
                .map(
                  (v) => DropdownMenuItem(
                    value: '${v['flow_id']}:${v['version']}',
                    child: Text(
                      '${v['name']} · v${v['version']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) => setState(() => _version = value),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || _account == null || _version == null
                    ? null
                    : () => _configure(true),
                icon: const Icon(Icons.smart_toy_outlined),
                label: const Text('Activar versión seleccionada'),
              ),
              OutlinedButton(
                onPressed: _busy || !enabled ? null : () => _configure(false),
                child: const Text('Desactivar bot'),
              ),
              TextButton(
                onPressed: _busy ? null : _load,
                child: const Text('Actualizar'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Si un operador responde desde ITONE o el celular, el bot se pausa en esa conversación. '
            'Reanúdalo desde la bandeja. Al reactivar, empieza un nuevo recorrido con el próximo mensaje. '
            'Las revisiones humanas esperan una aprobación o denegación en la bandeja.',
          ),
          if (data['failures']!.isNotEmpty) ...[
            const Divider(height: 32),
            const Text('Ejecuciones que requieren atención'),
            for (final failure in data['failures']!)
              ListTile(
                leading: const Icon(Icons.warning_amber),
                title: Text(
                  failure['error'] as String? ?? 'Error de automatización',
                ),
                subtitle: Text(failure['finished_at'] as String? ?? ''),
              ),
          ],
        ],
      ],
    );
  }
}

class ConversationBotControls extends StatefulWidget {
  const ConversationBotControls({
    super.key,
    required this.tenantId,
    required this.conversationId,
  });
  final String tenantId;
  final String conversationId;
  @override
  State<ConversationBotControls> createState() =>
      _ConversationBotControlsState();
}

class _ConversationBotControlsState extends State<ConversationBotControls> {
  Map<String, dynamic>? _session;
  String? _error;
  bool _busy = false;
  RealtimeChannel? _channel;
  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = _client
        .channel('bot-${widget.conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'whatsapp_bot_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversationId,
          ),
          callback: (_) => _load(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) _client.removeChannel(channel);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final session = await _client
          .from('whatsapp_bot_sessions')
          .select('status,error,node_id,review_pending')
          .eq('tenant_id', widget.tenantId)
          .eq('conversation_id', widget.conversationId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _session = session;
          _error = null;
        });
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _control(String action) async {
    String reason = '';
    if (action == 'deny') {
      final controller = TextEditingController();
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Denegar revisión'),
          content: TextField(
            controller: controller,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Motivo obligatorio'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text('Denegar'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (value == null) return;
      reason = value;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _client.rpc(
        'control_whatsapp_bot',
        params: {
          'p_tenant_id': widget.tenantId,
          'p_conversation_id': widget.conversationId,
          'p_action': action,
          'p_reason': reason,
        },
      );
      await _load();
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _session?['status'];
    final paused = status == 'human' || status == 'error';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(switch (status) {
                'human' => 'Atención humana',
                'error' => 'Bot detenido por error',
                'waiting' => 'Bot esperando respuesta',
                'running' => 'Bot en curso',
                'completed' => 'Flujo terminado',
                _ => 'Sin sesión de bot',
              }),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _control(paused ? 'resume' : 'pause'),
                child: Text(paused ? 'Reactivar bot' : 'Tomar conversación'),
              ),
              if (status == 'human' && _session?['review_pending'] == true) ...[
                TextButton(
                  onPressed: _busy ? null : () => _control('approve'),
                  child: const Text('Aprobar revisión'),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _control('deny'),
                  child: const Text('Denegar revisión'),
                ),
              ],
              IconButton(
                tooltip: 'Actualizar bot',
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          if (_session?['error'] != null)
            Text(
              _session!['error'] as String,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
