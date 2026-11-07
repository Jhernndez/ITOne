import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WhatsAppTemplatesRepository {
  WhatsAppTemplatesRepository(this.client);
  final SupabaseClient client;
  Future<Map<String, dynamic>> call(Map<String, dynamic> body) async {
    final response = await client.functions.invoke(
      'manage-whatsapp-templates',
      body: body,
    );
    final result = Map<String, dynamic>.from(response.data as Map);
    if (result['error'] != null) {
      throw FunctionException(status: response.status, details: result);
    }
    return result;
  }
}

class WhatsAppTemplatesPanel extends StatefulWidget {
  const WhatsAppTemplatesPanel({
    super.key,
    required this.tenantId,
    this.repository,
  });
  final String tenantId;
  final WhatsAppTemplatesRepository? repository;
  @override
  State<WhatsAppTemplatesPanel> createState() => _WhatsAppTemplatesPanelState();
}

class _WhatsAppTemplatesPanelState extends State<WhatsAppTemplatesPanel> {
  late final repository =
      widget.repository ??
      WhatsAppTemplatesRepository(Supabase.instance.client);
  List<Map<String, dynamic>> accounts = [], templates = [];
  String? accountId, after, error, notice;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    loadAccounts();
  }

  String failure(Object e) {
    if (e is FunctionException && e.details is Map) {
      final message = (e.details as Map)['error'];
      if (message is String) return message;
    }
    return 'No se pudo completar la operación. Revisa la conexión y la función de Supabase.';
  }

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> extra = const {},
  ]) => repository.call({
    'tenant_id': widget.tenantId,
    'account_id': accountId,
    'action': action,
    ...extra,
  });
  List<Map<String, dynamic>> rows(dynamic value) =>
      (value as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
  Future<void> loadAccounts() async {
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await call('accounts');
      if (!mounted) return;
      final available = rows(result['accounts']);
      setState(() {
        accounts = available;
        accountId = accounts.isEmpty ? null : accounts.first['id'] as String;
        templates = [];
        after = null;
      });
      if (accountId != null) await load();
    } catch (e) {
      if (mounted) setState(() => error = failure(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load({bool more = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await call('list', {
        if (more && after != null) 'after': after,
      });
      if (!mounted) return;
      final fetched = rows(result['templates']);
      setState(() {
        templates = more
            ? [
                ...templates,
                ...fetched.where(
                  (t) => !templates.any((old) => old['id'] == t['id']),
                ),
              ]
            : fetched;
        after = result['after'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => error = failure(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit([Map<String, dynamic>? original]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TemplateEditor(
        original: original,
        save: (template) => call(original == null ? 'create' : 'edit', {
          'template': template,
          if (original != null) ...{
            'template_id': original['id'],
            'name': original['name'],
          },
        }),
      ),
    ).then((_) async {
      if (mounted) await load();
    });
  }

  Future<void> remove(Map<String, dynamic> t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar plantilla de Meta'),
        content: Text(
          'Se eliminará "${t['name']}" (${t['language']}) de la cuenta seleccionada. '
          'Los envíos que la utilicen pueden fallar. Esta acción es real.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar de Meta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await call('delete', {'template_id': t['id'], 'name': t['name']});
      if (!mounted) return;
      setState(() => notice = 'Meta confirmó la eliminación.');
      await load();
    } catch (e) {
      if (mounted) setState(() => error = failure(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Plantillas de producción',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Cuenta real de este tenant. Crear y editar envía cambios a Meta; '
          'no envía mensajes. Meta determina aprobación, categoría y límites de edición. '
          'Nombre, idioma y categoría no se cambian al editar.',
        ),
        const SizedBox(height: 12),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (notice != null) Text(notice!),
        if (accounts.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey(accountId),
            initialValue: accountId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Cuenta de WhatsApp',
              border: OutlineInputBorder(),
            ),
            items: accounts
                .map(
                  (a) => DropdownMenuItem(
                    value: a['id'] as String,
                    child: Text(
                      '${a['name'] ?? 'WhatsApp'} · WABA ${a['waba_id']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (id) {
                    setState(() {
                      accountId = id;
                      templates = [];
                      after = null;
                      notice = null;
                    });
                    load();
                  },
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy || accountId == null ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('Crear plantilla'),
            ),
            OutlinedButton(
              onPressed: busy ? null : loadAccounts,
              child: const Text('Actualizar cuentas'),
            ),
            OutlinedButton(
              onPressed: busy || accountId == null ? null : () => load(),
              child: const Text('Actualizar plantillas'),
            ),
          ],
        ),
        if (!busy && accounts.isEmpty && error == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Conecta una cuenta de WhatsApp de esta empresa para gestionar sus plantillas.',
            ),
          ),
        if (!busy && accountId != null && templates.isEmpty && error == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Esta cuenta no tiene plantillas en el listado.'),
          ),
        for (final t in templates)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '${t['name']} · ${t['language']}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('Estado Meta: ${t['status']} · ${t['category']}'),
                  for (final c
                      in (t['components'] as List? ?? []).whereType<Map>())
                    if (c['text'] is String) Text(c['text'] as String),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: busy ? null : () => edit(t),
                        icon: const Icon(Icons.edit),
                        label: const Text('Editar'),
                      ),
                      TextButton.icon(
                        onPressed: busy ? null : () => remove(t),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Eliminar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (after != null)
          OutlinedButton(
            onPressed: busy ? null : () => load(more: true),
            child: const Text('Cargar más'),
          ),
      ],
    ),
  );
}

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({required this.original, required this.save});
  final Map<String, dynamic>? original;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) save;
  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  final name = TextEditingController(),
      body = TextEditingController(),
      header = TextEditingController(),
      footer = TextEditingController(),
      examples = TextEditingController(),
      headerExample = TextEditingController();
  final buttons =
      <
        ({TextEditingController text, TextEditingController value, String type})
      >[];
  String language = 'es', category = 'UTILITY';
  bool busy = false, done = false, supported = true;
  String? error, result;
  bool get editing => widget.original != null;
  static const languages = ['es', 'es_ES', 'es_MX', 'en_US', 'pt_BR'];
  @override
  void initState() {
    super.initState();
    final t = widget.original;
    if (t == null) return;
    name.text = t['name'] as String;
    language = t['language'] as String;
    category = t['category'] as String;
    supported =
        languages.contains(language) &&
        ['UTILITY', 'MARKETING'].contains(category);
    for (final c in (t['components'] as List? ?? []).whereType<Map>()) {
      switch (c['type']) {
        case 'HEADER':
          if (c['format'] != 'TEXT') supported = false;
          header.text = c['text'] as String? ?? '';
          final ex = c['example'];
          if (ex is Map &&
              ex['header_text'] is List &&
              (ex['header_text'] as List).isNotEmpty) {
            headerExample.text = '${(ex['header_text'] as List).first}';
          }
        case 'BODY':
          body.text = c['text'] as String? ?? '';
          final ex = c['example'];
          if (ex is Map &&
              ex['body_text'] is List &&
              (ex['body_text'] as List).isNotEmpty) {
            final first = (ex['body_text'] as List).first;
            if (first is List) examples.text = first.join('\n');
          }
        case 'FOOTER':
          footer.text = c['text'] as String? ?? '';
        case 'BUTTONS':
          final raw = c['buttons'];
          if (raw is! List || raw.length > 3) {
            supported = false;
            break;
          }
          for (final b in raw.whereType<Map>()) {
            final type = b['type'] as String? ?? '';
            final value = (b['url'] ?? b['phone_number'] ?? '') as String;
            if (!['QUICK_REPLY', 'URL', 'PHONE_NUMBER'].contains(type) ||
                value.contains('{{') ||
                b.keys.any(
                  (key) =>
                      !['type', 'text', 'url', 'phone_number'].contains(key),
                )) {
              supported = false;
            }
            buttons.add((
              type: type,
              text: TextEditingController(text: b['text'] as String? ?? ''),
              value: TextEditingController(text: value),
            ));
          }
        default:
          supported = false;
      }
    }
    if (t['parameter_format'] == 'NAMED') supported = false;
  }

  @override
  void dispose() {
    for (final c in [
      name,
      body,
      header,
      footer,
      examples,
      headerExample,
      ...buttons.expand((b) => [b.text, b.value]),
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !supported || done) return;
    if (!RegExp(r'^[a-z0-9_]{1,512}$').hasMatch(name.text) ||
        body.text.trim().isEmpty) {
      setState(
        () => error = 'Escribe un nombre en minúsculas sin espacios y un cuerpo de mensaje.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = await widget.save({
        'name': name.text,
        'language': language,
        'category': category,
        'header': header.text,
        'body': body.text,
        'footer': footer.text,
        'header_example': headerExample.text,
        'body_examples': examples.text.trim().isEmpty
            ? <String>[]
            : examples.text.trim().split('\n'),
        'buttons': buttons
            .map(
              (b) => {
                'type': b.type,
                'text': b.text.text,
                'value': b.value.text,
              },
            )
            .toList(),
      });
      if (!mounted) return;
      setState(() {
        done = true;
        result = editing
            ? 'Meta confirmó la edición. Actualiza para consultar el nuevo estado.'
            : 'Creada en Meta. ID: ${response['id']} · Estado: ${response['status']}. No implica aprobación.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => error =
            e is FunctionException &&
                e.details is Map &&
                (e.details as Map)['error'] is String
            ? (e.details as Map)['error'] as String
            : 'No se pudo confirmar la operación. Cierra y actualiza antes de reintentar.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController c,
    String label,
    int max, {
    int lines = 1,
    bool immutable = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      enabled: !busy && !done && supported && !immutable,
      maxLength: max,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 2,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        editing ? 'Editar plantilla en Meta' : 'Crear plantilla en Meta',
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Cambios reales en la cuenta seleccionada. Solo datos ficticios en ejemplos. '
                'Encabezado de texto, pie sin variables, respuestas rápidas o enlaces HTTPS fijos y teléfono.',
              ),
              if (!supported)
                const Text(
                  'Esta plantilla contiene formatos avanzados no compatibles con este editor. '
                  'Edítala en WhatsApp Manager para no perder componentes.',
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (result != null) SelectableText(result!),
              if (busy) const LinearProgressIndicator(),
              field(
                name,
                'Nombre (minúsculas, números y _)',
                512,
                immutable: editing,
              ),
              DropdownButtonFormField<String>(
                initialValue: language,
                decoration: const InputDecoration(labelText: 'Idioma'),
                items: {...languages, language}
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: editing || busy || done || !supported
                    ? null
                    : (v) => setState(() => language = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: {'UTILITY', 'MARKETING', category}
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: editing || busy || done || !supported
                    ? null
                    : (v) => setState(() => category = v!),
              ),
              const SizedBox(height: 12),
              field(header, 'Encabezado de texto (opcional)', 60),
              field(headerExample, 'Ejemplo para {{1}} del encabezado', 200),
              field(body, 'Cuerpo del mensaje', 1024, lines: 4),
              field(
                examples,
                'Ejemplos del cuerpo: uno por línea, en orden {{1}}, {{2}}',
                4000,
                lines: 3,
              ),
              field(footer, 'Pie de página (opcional)', 60),
              for (var i = 0; i < buttons.length; i++)
                Card(
                  key: ObjectKey(buttons[i].text),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: buttons[i].type,
                          items:
                              {
                                    'QUICK_REPLY',
                                    'URL',
                                    'PHONE_NUMBER',
                                    buttons[i].type,
                                  }
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v),
                                    ),
                                  )
                                  .toList(),
                          onChanged: busy || done || !supported
                              ? null
                              : (v) => setState(() {
                                  buttons[i] = (
                                    type: v!,
                                    text: buttons[i].text,
                                    value: buttons[i].value,
                                  );
                                }),
                        ),
                        field(buttons[i].text, 'Texto del botón', 25),
                        if (buttons[i].type != 'QUICK_REPLY')
                          field(
                            buttons[i].value,
                            buttons[i].type == 'URL'
                                ? 'URL HTTPS fija'
                                : 'Teléfono con + y código de país',
                            2000,
                          ),
                        TextButton(
                          onPressed: busy || done || !supported
                              ? null
                              : () {
                                  final removed = buttons[i];
                                  setState(() => buttons.removeAt(i));
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    removed.text.dispose();
                                    removed.value.dispose();
                                  });
                                },
                          child: const Text('Quitar botón'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (buttons.length < 3)
                OutlinedButton(
                  onPressed: busy || done || !supported
                      ? null
                      : () => setState(() {
                          buttons.add((
                            type: 'QUICK_REPLY',
                            text: TextEditingController(),
                            value: TextEditingController(),
                          ));
                        }),
                  child: const Text('Añadir botón'),
                ),
              const SizedBox(height: 8),
              const Text(
                'Vista previa del contenido',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              AnimatedBuilder(
                animation: Listenable.merge([header, body, footer]),
                builder: (_, _) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      [
                        header.text,
                        body.text,
                        footer.text,
                      ].where((s) => s.isNotEmpty).join('\n\n'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(done ? 'Cerrar' : 'Cancelar'),
        ),
        if (!done)
          FilledButton(
            onPressed: busy || !supported ? null : submit,
            child: Text(
              editing ? 'Guardar cambios en Meta' : 'Crear y enviar a Meta',
            ),
          ),
      ],
    ),
  );
}
