import 'dart:convert';

import 'package:flutter/material.dart';

class _MappingRow {
  _MappingRow(String key, String value, List<String> variables)
    : key = TextEditingController(text: key),
      literal = TextEditingController(text: value),
      variable = RegExp(r'^\{\{([a-zA-Z][a-zA-Z0-9_]*)\}\}$')
          .firstMatch(value)?[1] {
    if (!variables.contains(variable)) variable = null;
    if (variable != null) literal.clear();
  }
  final TextEditingController key;
  final TextEditingController literal;
  String? variable;
  void dispose() {
    key.dispose();
    literal.dispose();
  }
}

class ApiMappingDialog extends StatefulWidget {
  const ApiMappingDialog({
    super.key,
    required this.query,
    required this.body,
    required this.variables,
    this.getOnly = false,
  });
  final String query;
  final String body;
  final List<String> variables;
  final bool getOnly;
  @override
  State<ApiMappingDialog> createState() => _ApiMappingDialogState();
}

class _ApiMappingDialogState extends State<ApiMappingDialog> {
  final query = <_MappingRow>[];
  final body = <_MappingRow>[];
  final removed = <_MappingRow>[];
  String? error;
  bool supported = true;

  @override
  void initState() {
    super.initState();
    try {
      void load(String raw, List<_MappingRow> target) {
        final value = jsonDecode(raw.trim().isEmpty ? '{}' : raw);
        if (value is! Map ||
            value.entries.any((e) => e.key is! String || e.value is! String)) {
          throw const FormatException(
            'El asistente solo edita objetos simples con valores de texto. Usa JSON avanzado para otros tipos.',
          );
        }
        for (final entry in value.entries) {
          final text = entry.value as String;
          final placeholder = RegExp(r'\{\{[a-zA-Z][a-zA-Z0-9_.]*\}\}')
              .firstMatch(text);
          if (placeholder != null &&
              (placeholder.group(0) != text ||
                  !widget.variables.contains(
                    text.substring(2, text.length - 2),
                  ))) {
            throw const FormatException(
              'Este valor contiene una variable avanzada. Usa JSON avanzado para conservarla.',
            );
          }
          target.add(
            _MappingRow(
              entry.key as String,
              entry.value as String,
              widget.variables,
            ),
          );
        }
      }

      load(widget.query, query);
      load(widget.body, body);
    } on FormatException catch (e) {
      error = e.message;
      supported = false;
    }
  }

  @override
  void dispose() {
    for (final row in [...query, ...body, ...removed]) {
      row.dispose();
    }
    super.dispose();
  }

  Map<String, String> _values(List<_MappingRow> rows) {
    final result = <String, String>{};
    for (final row in rows) {
      final key = row.key.text.trim();
      if (key.isEmpty || result.containsKey(key)) {
        throw const FormatException('Cada dato necesita un nombre único.');
      }
      if (row.variable == null &&
          RegExp(r'\{\{[a-zA-Z][a-zA-Z0-9_.]*\}\}')
              .hasMatch(row.literal.text)) {
        throw const FormatException(
          'Selecciona las variables en Origen; no las escribas como texto fijo.',
        );
      }
      result[key] = row.variable == null
          ? row.literal.text
          : '{{${row.variable}}}';
    }
    return result;
  }

  Widget _group(String title, List<_MappingRow> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      for (final row in rows)
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: row.key,
                decoration: const InputDecoration(labelText: 'Nombre del dato'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: row.variable ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Origen'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Texto fijo')),
                  for (final variable in widget.variables)
                    DropdownMenuItem(
                      value: variable,
                      child: Text(variable, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) => setState(
                  () => row.variable = value?.isEmpty == true ? null : value,
                ),
              ),
            ),
            if (row.variable == null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: row.literal,
                  decoration: const InputDecoration(labelText: 'Valor fijo'),
                ),
              ),
            ],
            IconButton(
              tooltip: 'Quitar dato',
              onPressed: () => setState(() {
                rows.remove(row);
                removed.add(row);
              }),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      TextButton.icon(
        onPressed: () =>
            setState(() => rows.add(_MappingRow('', '', widget.variables))),
        icon: const Icon(Icons.add),
        label: const Text('Agregar dato'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Datos para la API'),
    content: SizedBox(
      width: 700,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Selecciona una variable del flujo o escribe un valor fijo. El nombre del dato lo define la API de destino.',
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (supported) ...[
              _group('Parámetros de consulta', query),
              if (widget.getOnly)
                const Text('GET no envía cuerpo; usa parámetros de consulta.')
              else
                _group('Datos del cuerpo', body),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      if (supported)
        FilledButton(
          onPressed: () {
            try {
              Navigator.pop(context, (
                query: jsonEncode(_values(query)),
                body: jsonEncode(_values(body)),
              ));
            } on FormatException catch (e) {
              setState(() => error = e.message);
            }
          },
          child: const Text('Aplicar'),
        ),
    ],
  );
}
