import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ExternalApiRepository {
  ExternalApiRepository(this.client);
  final SupabaseClient client;

  Future<List<Map<String, dynamic>>> list(String tenantId) async {
    final rows = await client
        .from('tenant_api_integrations')
        .select(
          'id,name,base_url,auth_type,enabled,tenant_api_resources(id,name,path,http_method,enabled,enabled_for_automation,allow_automation_writes)',
        )
        .eq('tenant_id', tenantId)
        .order('name');
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> body) async {
    final response = await client.functions.invoke(
      'manage-internal-api',
      body: body,
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    if (data['error'] != null) {
      throw FunctionException(status: response.status, details: data);
    }
    return data;
  }

  Future<void> saveResource(
    String tenantId,
    String integrationId,
    String? id,
    Map<String, dynamic> values,
  ) async {
    final payload = {
      ...values,
      'tenant_id': tenantId,
      'integration_id': integrationId,
    };
    if (id == null) {
      await client
          .from('tenant_api_resources')
          .insert(payload)
          .select('id')
          .single();
    } else {
      await client
          .from('tenant_api_resources')
          .update(payload)
          .eq('tenant_id', tenantId)
          .eq('integration_id', integrationId)
          .eq('id', id)
          .select('id')
          .single();
    }
  }

  Future<void> delete(String table, String tenantId, String id) async {
    await client
        .from(table)
        .delete()
        .eq('tenant_id', tenantId)
        .eq('id', id)
        .select('id')
        .single();
  }
}

class ExternalApiPanel extends StatefulWidget {
  const ExternalApiPanel({super.key, required this.tenantId, this.repository});
  final String tenantId;
  final ExternalApiRepository? repository;

  @override
  State<ExternalApiPanel> createState() => _ExternalApiPanelState();
}

class _ExternalApiPanelState extends State<ExternalApiPanel> {
  late final repo =
      widget.repository ?? ExternalApiRepository(Supabase.instance.client);
  List<Map<String, dynamic>> integrations = [];
  bool busy = true;
  String? error;
  Map<String, dynamic>? result;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant ExternalApiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tenantId != oldWidget.tenantId) {
      integrations = [];
      result = null;
      load();
    }
  }

  String failure(Object e) {
    if (e is FunctionException && e.details is Map) {
      final details = e.details as Map;
      final message = details['error']?.toString() ?? 'Error de la función';
      return details['outcome'] == 'unknown'
          ? '$message. La operación podría haberse aplicado; verifica antes de repetir.'
          : message;
    }
    if (e is PostgrestException) return e.message;
    return 'No se pudo completar la operación. Verifica la conexión.';
  }

  Future<void> load() async {
    final tenant = widget.tenantId;
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
        result = null;
      });
    }
    try {
      final data = await repo.list(tenant);
      if (mounted && tenant == widget.tenantId) {
        setState(() => integrations = data);
      }
    } catch (e) {
      if (mounted && tenant == widget.tenantId) {
        setState(() => error = failure(e));
      }
    } finally {
      if (mounted && tenant == widget.tenantId) setState(() => busy = false);
    }
  }

  Future<void> perform(
    Future<void> Function() operation, {
    bool refresh = false,
  }) async {
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      await operation();
      if (refresh) await load();
    } catch (e) {
      if (mounted) setState(() => error = failure(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;

  Future<T?> dialog<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final value = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    return value;
  }

  Future<void> editIntegration([Map<String, dynamic>? item]) async {
    final name = TextEditingController(text: item?['name'] as String? ?? '');
    final url = TextEditingController(text: item?['base_url'] as String? ?? '');
    final header = TextEditingController();
    final secret = TextEditingController();
    final username = TextEditingController();
    const supportedTypes = ['none', 'api_key', 'bearer_token', 'basic'];
    var type = item?['auth_type'] as String? ?? 'none';
    var enabled = item?['enabled'] as bool? ?? true;
    String? validation;
    final values = await dialog<Map<String, dynamic>>(
      (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            item == null ? 'Nueva integración API' : 'Editar integración API',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nombre'),
                  ),
                  TextField(
                    controller: url,
                    decoration: const InputDecoration(
                      labelText: 'URL base HTTPS',
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: 'Autenticación',
                    ),
                    items: [
                      if (item != null &&
                          !supportedTypes.contains(item['auth_type']))
                        DropdownMenuItem(
                          value: item['auth_type'] as String,
                          child: const Text('Tipo anterior no compatible'),
                        ),
                      const DropdownMenuItem(
                        value: 'none',
                        child: Text('Sin autenticación'),
                      ),
                      const DropdownMenuItem(
                        value: 'api_key',
                        child: Text('API key'),
                      ),
                      const DropdownMenuItem(
                        value: 'bearer_token',
                        child: Text('Bearer token'),
                      ),
                      const DropdownMenuItem(
                        value: 'basic',
                        child: Text('Usuario y contraseña'),
                      ),
                    ],
                    onChanged: (v) => update(() => type = v!),
                  ),
                  if (item != null)
                    const Text(
                      'Deja las credenciales vacías para conservarlas si no cambias el tipo.',
                    ),
                  if (type == 'api_key')
                    TextField(
                      controller: header,
                      decoration: const InputDecoration(
                        labelText: 'Nombre de cabecera',
                      ),
                    ),
                  if (type == 'basic')
                    TextField(
                      controller: username,
                      decoration: const InputDecoration(labelText: 'Usuario'),
                    ),
                  if (supportedTypes.contains(type) && type != 'none')
                    TextField(
                      controller: secret,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: type == 'basic'
                            ? 'Contraseña'
                            : type == 'api_key'
                            ? 'Valor API key'
                            : 'Token',
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('Integración habilitada'),
                    value: enabled,
                    onChanged: (v) => update(() => enabled = v),
                  ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
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
                if (!supportedTypes.contains(type)) {
                  update(
                    () => validation =
                        'Selecciona un tipo de autenticación compatible.',
                  );
                  return;
                }
                final uri = Uri.tryParse(url.text.trim());
                if (name.text.trim().isEmpty ||
                    uri == null ||
                    uri.scheme != 'https' ||
                    uri.host.isEmpty) {
                  update(
                    () => validation = 'Indica nombre y URL HTTPS válidos.',
                  );
                  return;
                }
                final config = <String, String>{
                  if (type == 'api_key') ...{
                    'header_name': header.text,
                    'header_value': secret.text,
                  },
                  if (type == 'bearer_token') 'token': secret.text,
                  if (type == 'basic') ...{
                    'username': username.text,
                    'password': secret.text,
                  },
                };
                Navigator.pop(context, {
                  'action': 'upsert_integration',
                  'tenant_id': widget.tenantId,
                  if (item != null) 'integration_id': item['id'],
                  'name': name.text.trim(),
                  'base_url': url.text.trim(),
                  'auth_type': type,
                  'auth_config': config,
                  'enabled': enabled,
                });
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    url.dispose();
    header.dispose();
    secret.dispose();
    username.dispose();
    if (values != null && mounted) {
      await perform(() async {
        await repo.call(values);
      }, refresh: true);
    }
  }

  Future<void> editResource(
    String integrationId, [
    Map<String, dynamic>? item,
  ]) async {
    final name = TextEditingController(text: item?['name'] as String? ?? '');
    final path = TextEditingController(text: item?['path'] as String? ?? '');
    var method = item?['http_method'] as String? ?? 'GET';
    var enabled = item?['enabled'] as bool? ?? true;
    var automation = item?['enabled_for_automation'] as bool? ?? false;
    var writes = item?['allow_automation_writes'] as bool? ?? false;
    String? validation;
    final values = await dialog<Map<String, dynamic>>(
      (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(item == null ? 'Nuevo recurso' : 'Editar recurso'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Nombre del recurso',
                    ),
                  ),
                  TextField(
                    controller: path,
                    decoration: const InputDecoration(
                      labelText: 'Ruta relativa (ej. /clientes)',
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: method,
                    decoration: const InputDecoration(labelText: 'Método'),
                    items: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE']
                        .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (v) => update(() => method = v!),
                  ),
                  SwitchListTile(
                    title: const Text('Recurso habilitado'),
                    value: enabled,
                    onChanged: (v) => update(() => enabled = v),
                  ),
                  SwitchListTile(
                    title: const Text('Permitir en automatizaciones'),
                    value: automation,
                    onChanged: (v) => update(() {
                      automation = v;
                      if (!v) writes = false;
                    }),
                  ),
                  SwitchListTile(
                    title: const Text('Permitir escrituras automáticas'),
                    subtitle: const Text(
                      'POST, PUT, PATCH y DELETE pueden modificar datos externos.',
                    ),
                    value: writes,
                    onChanged: automation
                        ? (v) => update(() => writes = v)
                        : null,
                  ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
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
                if (name.text.trim().isEmpty ||
                    !path.text.startsWith('/') ||
                    path.text.startsWith('//')) {
                  update(
                    () => validation = 'Indica nombre y ruta relativa válida.',
                  );
                  return;
                }
                Navigator.pop(context, {
                  'name': name.text.trim(),
                  'path': path.text.trim(),
                  'http_method': method,
                  'enabled': enabled,
                  'enabled_for_automation': automation,
                  'allow_automation_writes': writes,
                });
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    path.dispose();
    if (values != null && mounted) {
      await perform(
        () => repo.saveResource(
          widget.tenantId,
          integrationId,
          item?['id'] as String?,
          values,
        ),
        refresh: true,
      );
    }
  }

  Future<void> execute(Map<String, dynamic> resource) async {
    final query = TextEditingController(text: '{}');
    final body = TextEditingController();
    final method = resource['http_method'] as String;
    String? validation;
    final values = await dialog<Map<String, dynamic>>(
      (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Ejecutar ${resource['name']} ($method)'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: query,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Parámetros JSON (objeto)',
                    ),
                  ),
                  if (method != 'GET')
                    TextField(
                      controller: body,
                      minLines: 2,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Cuerpo JSON (opcional)',
                      ),
                    ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
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
                try {
                  final parsed = jsonDecode(query.text);
                  if (parsed is! Map ||
                      parsed.values.any(
                        (v) =>
                            v != null &&
                            v is! String &&
                            v is! num &&
                            v is! bool,
                      )) {
                    throw const FormatException();
                  }
                  final parsedBody = body.text.trim().isEmpty
                      ? null
                      : jsonDecode(body.text);
                  jsonEncode(parsed);
                  if (body.text.trim().isNotEmpty) jsonEncode(parsedBody);
                  Navigator.pop(context, {
                    'query': parsed,
                    if (body.text.trim().isNotEmpty) 'body': parsedBody,
                  });
                } catch (_) {
                  update(
                    () => validation = 'JSON inválido: parámetros deben ser un objeto de valores simples.',
                  );
                }
              },
              child: const Text('Continuar'),
            ),
          ],
        ),
      ),
    );
    query.dispose();
    body.dispose();
    if (values == null || !mounted) return;
    if (method != 'GET' &&
        !await confirm(
          'Confirmar ejecución',
          '$method puede modificar o eliminar datos en el sistema externo.',
        )) {
      return;
    }
    if (!mounted) return;
    await perform(() async {
      final data = await repo.call({
        'action': 'execute_resource',
        'tenant_id': widget.tenantId,
        'resource_id': resource['id'],
        ...values,
      });
      if (mounted) setState(() => result = data);
    });
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'APIs de la empresa',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                onPressed: busy ? null : load,
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh),
              ),
              FilledButton(
                onPressed: busy ? null : () => editIntegration(),
                child: const Text('Nueva API'),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            SelectableText(
              'Error: $error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!busy && integrations.isEmpty)
            const Text('No hay APIs configuradas.'),
          for (final integration in integrations)
            Card(
              child: ExpansionTile(
                title: Text(integration['name'] as String),
                subtitle: Text(
                  '${integration['base_url']} · ${integration['enabled'] == true ? "Habilitada" : "Deshabilitada"}',
                ),
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => editIntegration(integration),
                        child: const Text('Editar API'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => perform(() async {
                                final data = await repo.call({
                                  'action': 'test_connection',
                                  'tenant_id': widget.tenantId,
                                  'integration_id': integration['id'],
                                });
                                if (mounted) setState(() => result = data);
                              }),
                        child: const Text('Probar conexión'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => editResource(integration['id'] as String),
                        child: const Text('Añadir recurso'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () async {
                                if (await confirm(
                                      'Eliminar API',
                                      'También se eliminarán sus recursos.',
                                    ) &&
                                    mounted) {
                                  await perform(
                                    () => repo.delete(
                                      'tenant_api_integrations',
                                      widget.tenantId,
                                      integration['id'] as String,
                                    ),
                                    refresh: true,
                                  );
                                }
                              },
                        child: const Text('Eliminar API'),
                      ),
                    ],
                  ),
                  for (final resource
                      in (integration['tenant_api_resources'] as List? ?? []))
                    ListTile(
                      title: Text(
                        '${resource['name']} · ${resource['http_method']} ${resource['path']}',
                      ),
                      subtitle: Text(
                        '${resource['enabled'] == true ? "Habilitado" : "Deshabilitado"} · Automatización: ${resource['enabled_for_automation'] == true ? "sí" : "no"} · Escrituras: ${resource['allow_automation_writes'] == true ? "sí" : "no"}',
                      ),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            tooltip: 'Ejecutar recurso',
                            onPressed: busy
                                ? null
                                : () => execute(
                                    Map<String, dynamic>.from(resource),
                                  ),
                            icon: const Icon(Icons.play_arrow),
                          ),
                          IconButton(
                            tooltip: 'Editar recurso',
                            onPressed: busy
                                ? null
                                : () => editResource(
                                    integration['id'] as String,
                                    Map<String, dynamic>.from(resource),
                                  ),
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            tooltip: 'Eliminar recurso',
                            onPressed: busy
                                ? null
                                : () async {
                                    if (await confirm(
                                          'Eliminar recurso',
                                          'Esta acción no se puede deshacer.',
                                        ) &&
                                        mounted) {
                                      await perform(
                                        () => repo.delete(
                                          'tenant_api_resources',
                                          widget.tenantId,
                                          resource['id'] as String,
                                        ),
                                        refresh: true,
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (result != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Resultado HTTP ${result!['status_code']} · ${result!['ok'] == true ? "Correcto" : "Error"}',
                    ),
                    const Text(
                      'Respuesta del proveedor (result.body). Para mapear JSON usa '
                      'result.body.campo; result.body.data solo existe si el proveedor '
                      'incluye "data". No existe result.data.',
                    ),
                    SelectableText(
                      const JsonEncoder.withIndent('  ')
                          .convert(result!['body']),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
