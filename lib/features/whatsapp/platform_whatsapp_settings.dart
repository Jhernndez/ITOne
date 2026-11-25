import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlatformWhatsAppRepository {
  PlatformWhatsAppRepository(this.client);
  final SupabaseClient client;

  Future<Map<String, dynamic>> call(String action, {String? tenantId}) async {
    final response = await client.functions.invoke(
      action == 'validate'
          ? 'validate-whatsapp-integration'
          : 'platform-whatsapp-settings',
      body: {
        if (action != 'validate') 'action': action,
        'tenant_id': ?tenantId,
      },
    );
    final result = Map<String, dynamic>.from(response.data as Map);
    if (result['error'] != null) {
      throw FunctionException(status: response.status, details: result);
    }
    return result;
  }
}

class PlatformWhatsAppSettings extends StatefulWidget {
  const PlatformWhatsAppSettings({super.key, this.repository});
  final PlatformWhatsAppRepository? repository;

  @override
  State<PlatformWhatsAppSettings> createState() =>
      _PlatformWhatsAppSettingsState();
}

class _PlatformWhatsAppSettingsState extends State<PlatformWhatsAppSettings> {
  late final repository =
      widget.repository ?? PlatformWhatsAppRepository(Supabase.instance.client);
  Map<String, dynamic>? configuration, diagnostics, validation;
  List<Map<String, dynamic>> tenants = [];
  String? tenantId, error;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FunctionException && e.details is Map
              ? (e.details as Map)['error']?.toString() ??
                    'No se pudo consultar Meta.'
              : 'No se pudo consultar la configuración. Revisa la conexión y las funciones de Supabase.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => run(() async {
    final config = await repository.call('configuration');
    final result = await repository.call('tenants');
    if (!mounted) return;
    setState(() {
      configuration = config;
      tenants = (result['tenants'] as List)
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();
      tenantId = tenants.any((t) => t['id'] == tenantId)
          ? tenantId
          : tenants.firstOrNull?['id'] as String?;
      diagnostics = null;
      validation = null;
    });
    if (tenantId != null) await readDiagnostics();
  });

  Future<void> readDiagnostics() async {
    final result = await repository.call('diagnostics', tenantId: tenantId);
    if (mounted) setState(() => diagnostics = result);
  }

  Future<void> validate() => run(() async {
    final result = await repository.call('validate', tenantId: tenantId);
    if (!mounted) return;
    setState(() => validation = result);
    await readDiagnostics();
  });

  Widget detail(String label, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: SelectableText('$label: ${value ?? 'No configurado'}'),
  );

  @override
  Widget build(BuildContext context) {
    final config = configuration;
    final integration = diagnostics?['integration'] as Map?;
    final accounts = diagnostics?['accounts'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp · Configuración de plataforma'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Una sola aplicación de Meta para ITONE. Cada empresa autoriza su '
            'propio WhatsApp desde Conectar WhatsApp Business; no necesita crear '
            'una app de Meta ni copiar tokens o identificadores.',
          ),
          const SizedBox(height: 12),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          OutlinedButton(
            onPressed: busy ? null : load,
            child: const Text('Actualizar configuración'),
          ),
          if (config != null) ...[
            const SizedBox(height: 12),
            const Text(
              'Aplicación global de Meta',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            detail('App ID', config['app_id']),
            detail('Embedded Signup Config ID', config['config_id']),
            detail('Graph API', config['graph_version']),
            detail('Webhook', config['webhook_url']),
            detail(
              'App Secret',
              config['app_secret_configured'] == true
                  ? 'Configurado'
                  : 'Falta configurar',
            ),
            detail(
              'Token de verificación del webhook',
              config['webhook_verify_token_configured'] == true
                  ? 'Configurado'
                  : 'Falta configurar',
            ),
            const Text(
              'Los valores globales se administran en Supabase → Edge Functions → Secrets: '
              'META_APP_ID, META_APP_SECRET, META_WHATSAPP_CONFIG_ID, META_GRAPH_VERSION '
              'y WHATSAPP_VERIFY_TOKEN. Los secretos y tokens de las empresas nunca se muestran aquí. '
              'La configuración global no es un número de WhatsApp.',
            ),
            detail(
              'Worker de automatizaciones',
              config['bot_worker_configured'] == true
                  ? 'Configurado'
                  : 'Falta configurar',
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'Diagnóstico por empresa',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          if (tenants.isEmpty && !busy && error == null)
            const Text('No hay empresas disponibles.'),
          if (tenants.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey(tenantId),
              initialValue: tenantId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Empresa'),
              items: tenants
                  .map(
                    (t) => DropdownMenuItem(
                      value: t['id'] as String,
                      child: Text(
                        t['name'] as String,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: busy
                  ? null
                  : (id) {
                      setState(() {
                        tenantId = id;
                        diagnostics = null;
                        validation = null;
                      });
                      run(readDiagnostics);
                    },
            ),
          if (diagnostics != null) ...[
            detail('Estado guardado', integration?['status'] ?? 'Sin conexión'),
            detail(
              'WABA de la integración',
              integration?['business_account_id'],
            ),
            detail(
              'Phone Number ID de la integración',
              integration?['phone_number_id'],
            ),
            const Text(
              'Cuentas guardadas (no certifican acceso actual en Meta):',
            ),
            for (final account in accounts.whereType<Map>())
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      detail('Canal', account['name']),
                      detail('Número', account['display_phone_number']),
                      detail('WABA', account['business_account_id']),
                      detail('Phone Number ID', account['phone_number_id']),
                      detail('Modalidad', account['onboarding_mode']),
                      detail('Estado guardado', account['status']),
                    ],
                  ),
                ),
              ),
          ],
          OutlinedButton.icon(
            onPressed: busy || integration == null ? null : validate,
            icon: const Icon(Icons.verified_outlined),
            label: const Text('Validar conexión con Meta'),
          ),
          const Text(
            'Consulta Meta y actualiza el estado de la integración seleccionada. '
            'No conecta, registra, elimina ni migra el número. No garantiza la entrega de mensajes.',
          ),
          if (validation != null) ...[
            detail('Resultado', validation!['message']),
            detail('Estado', validation!['status']),
            for (final key in [
              'phone_status',
              'quality_rating',
              'messaging_limit_tier',
              'blocked_entities',
            ])
              if (validation![key] != null) detail(key, validation![key]),
          ],
        ],
      ),
    );
  }
}
