import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlatformWhatsAppRepository {
  PlatformWhatsAppRepository(this.client);
  final SupabaseClient client;
  Future<Map<String, dynamic>> saveConfiguration(
    Map<String, String> values,
  ) async {
    final response = await client.functions.invoke(
      'platform-whatsapp-settings',
      body: {'action': 'save_configuration', ...values},
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

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
  Map<String, dynamic>? configuration, diagnostics, validation, appValidation;
  List<Map<String, dynamic>> tenants = [];
  String? tenantId, error;
  bool busy = true;
  String? notice;
  final _appId = TextEditingController();
  final _configId = TextEditingController();
  final _appSecret = TextEditingController();
  final _verifyToken = TextEditingController();

  @override
  void dispose() {
    _appId.dispose();
    _configId.dispose();
    _appSecret.dispose();
    _verifyToken.dispose();
    super.dispose();
  }

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
    if (!mounted) return;
    setState(() => configuration = config);
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

  Future<void> checkApp() => run(() async {
    setState(() => appValidation = null);
    final result = await repository.call('check_app');
    if (mounted) setState(() => appValidation = result);
  });

  Future<void> configureWebhooks() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Activar eventos de coexistencia'),
        content: const Text(
          'Se agregarán las suscripciones de mensajes del celular, contactos e historial '
          'al webhook global de Meta, conservando los eventos existentes. No registra números ni reintenta envíos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Activar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await run(() async {
      final result = await repository.call('configure_coexistence_webhooks');
      if (mounted) setState(() => appValidation = result);
    });
  }

  Future<void> editConfiguration() async {
    final appId = _appId..text = configuration?['app_id'] as String? ?? '';
    final configId = _configId
      ..text = configuration?['config_id'] as String? ?? '';
    final appSecret = _appSecret..clear();
    final verifyToken = _verifyToken..clear();
    final form = GlobalKey<FormState>();
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Configurar aplicación de Meta'),
        content: SizedBox(
          width: 500,
          child: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Una configuración global para ITONE. No ingreses el teléfono ni tokens de cada cliente. '
                    'Los secretos están protegidos: deja los campos vacíos para conservarlos. '
                    'Cambiar el token del webhook requiere actualizar también su verificación en Meta.',
                  ),
                  TextFormField(
                    controller: appId,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'App ID'),
                    validator: (v) =>
                        RegExp(r'^\d{5,30}$').hasMatch(v?.trim() ?? '')
                        ? null
                        : 'ID numérico obligatorio',
                  ),
                  TextFormField(
                    controller: configId,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Embedded Signup Config ID',
                    ),
                    validator: (v) =>
                        RegExp(r'^\d{5,30}$').hasMatch(v?.trim() ?? '')
                        ? null
                        : 'ID numérico obligatorio',
                  ),
                  TextFormField(
                    controller: appSecret,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'App Secret (opcional)',
                      hintText: configuration?['app_secret_configured'] == true
                          ? 'Configurado · dejar vacío para conservar'
                          : 'Falta configurar',
                    ),
                  ),
                  TextFormField(
                    controller: verifyToken,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Token de verificación del webhook (opcional)',
                      hintText:
                          configuration?['webhook_verify_token_configured'] ==
                              true
                          ? 'Configurado · dejar vacío para conservar'
                          : 'Falta configurar',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              if (!form.currentState!.validate()) return;
              Navigator.pop(context, <String, String>{
                'app_id': appId.text.trim(),
                'config_id': configId.text.trim(),
                if (appSecret.text.trim().isNotEmpty)
                  'app_secret': appSecret.text.trim(),
                if (verifyToken.text.trim().isNotEmpty)
                  'verify_token': verifyToken.text.trim(),
              });
            },
            child: const Text('Verificar y guardar'),
          ),
        ],
      ),
    );
    if (!mounted) {
      values?.clear();
      return;
    }
    appSecret.clear();
    verifyToken.clear();
    if (values == null || !mounted) return;
    await run(() async {
      final result = await repository.saveConfiguration(values);
      final config = await repository.call('configuration');
      if (mounted) {
        setState(() {
          configuration = config;
          appValidation = null;
          notice = result['message'] as String?;
        });
      }
    });
    values.remove('app_secret');
    values.remove('verify_token');
  }

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
          if (notice != null) Text(notice!),
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
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : editConfiguration,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Editar configuración de Meta'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : checkApp,
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Comprobar aplicación de Meta'),
                ),
              ],
            ),
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
              'Los IDs y secretos existentes de Supabase se conservan. Puedes actualizar la aplicación '
              'desde esta pantalla; los nuevos secretos se guardan cifrados en Vault y nunca se muestran. '
              'La versión de Graph se administra en META_GRAPH_VERSION en Supabase. '
              'La configuración global no es un número de WhatsApp.',
            ),
            detail(
              'Worker de automatizaciones',
              config['bot_worker_configured'] == true
                  ? 'Configurado'
                  : 'Falta configurar',
            ),
          ],
          if (appValidation != null) ...[
            const Divider(height: 24),
            detail('Aplicación verificada', appValidation!['app_name']),
            detail('App ID verificado', appValidation!['app_id']),
            detail(
              'Credenciales de aplicación',
              appValidation!['app_credentials_valid'] == true
                  ? 'Válidas'
                  : 'No confirmadas',
            ),
            detail(
              'Webhook de ITONE en Meta',
              appValidation!['webhook_matches'] == true
                  ? 'Coincide'
                  : 'No coincide o no está suscrito',
            ),
            detail(
              'Webhook activo en Meta',
              appValidation!['webhook_active'] == true ? 'Sí' : 'No confirmado',
            ),
            detail('Campos suscritos', appValidation!['webhook_fields']),
            if (appValidation!['coexistence_missing_fields'] is List) ...[
              detail(
                'Eventos de coexistencia',
                appValidation!['coexistence_webhooks_ready'] == true
                    ? 'Completos'
                    : 'Faltan: ${appValidation!['coexistence_missing_fields']}',
              ),
              if (appValidation!['coexistence_webhooks_ready'] != true)
                OutlinedButton.icon(
                  onPressed: busy ? null : configureWebhooks,
                  icon: const Icon(Icons.sync),
                  label: const Text('Activar eventos de coexistencia'),
                ),
            ],
            Text(appValidation!['message'] as String? ?? ''),
          ],
          const SizedBox(height: 24),
          const Text(
            'Diagnóstico por empresa',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Cada empresa autoriza su propio WhatsApp Business por coexistencia. '
            'La conexión global de ITONE con Meta se administra arriba; '
            'aquí no se ingresan tokens ni se registran números.',
          ),
          const SizedBox(height: 12),
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
            if (integration == null && accounts.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'WhatsApp sin conectar',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Esta empresa todavía no tiene una conexión de WhatsApp guardada en ITONE. '
                        'Su administrador debe entrar al espacio de la empresa → '
                        'Configuración → WhatsApp → Integración → Conectar WhatsApp Business.',
                      ),
                      SizedBox(height: 8),
                      Text(
                        'La autorización debe completarse por coexistencia para utilizar '
                        'el número en el celular y en ITONE. Este estado no confirma '
                        'la elegibilidad ni elimina registros del número en Meta.',
                      ),
                    ],
                  ),
                ),
              ),
            if (integration != null)
              detail(
                'Estado de la integración guardado',
                integration['status'],
              ),
            if (integration != null && accounts.isEmpty)
              const Text(
                'Hay un registro de integración, pero no una cuenta de WhatsApp asociada. '
                'No se puede confirmar una conexión operativa; revisa la autorización de la empresa.',
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
                      detail('Conexión', switch (account['onboarding_mode']) {
                        'coexistence' => 'Coexistencia',
                        'cloud_api' =>
                          'Cloud API antigua · sin coexistencia acreditada',
                        _ => 'Modalidad no confirmada',
                      }),
                      detail('Estado guardado', account['status']),
                      Text(
                        account['onboarding_mode'] == 'coexistence'
                            ? 'Coexistencia guardada al autorizar con Meta. El estado guardado '
                                  'no garantiza el acceso actual ni la entrega de mensajes.'
                            : 'Este registro no acredita el uso simultáneo con WhatsApp Business '
                                  'móvil. La empresa debe completar la autorización por coexistencia.',
                      ),
                      ExpansionTile(
                        key: ValueKey('account-$tenantId-${account['id']}'),
                        title: const Text(
                          'Identificadores técnicos de la cuenta',
                        ),
                        children: [
                          detail('WABA', account['business_account_id']),
                          detail('Phone Number ID', account['phone_number_id']),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (integration != null)
              ExpansionTile(
                key: ValueKey('integration-$tenantId'),
                title: const Text('Identificadores técnicos de la integración'),
                children: [
                  const Text(
                    'Datos guardados en Supabase, asignados por Meta a la empresa. '
                    'No son el App ID ni el Config ID globales de ITONE.',
                  ),
                  detail(
                    'WABA de la integración',
                    integration['business_account_id'],
                  ),
                  detail(
                    'Phone Number ID de la integración',
                    integration['phone_number_id'],
                  ),
                ],
              ),
          ],
          OutlinedButton.icon(
            onPressed: busy || integration == null ? null : validate,
            icon: const Icon(Icons.verified_outlined),
            label: const Text('Validar conexión con Meta'),
          ),
          if (integration != null)
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
