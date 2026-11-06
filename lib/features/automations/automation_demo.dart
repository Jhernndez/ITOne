import 'package:flutter/material.dart';

import 'patient_automation_demo.dart';

enum DemoAutomation { outOfHours, welcome }

class DemoAutomationResult {
  const DemoAutomationResult(this.rule, this.response, this.trace);
  final DemoAutomation? rule;
  final String? response;
  final List<String> trace;
}

DemoAutomationResult simulateAutomation({
  required bool outOfHoursEnabled,
  required bool welcomeEnabled,
  required bool isNewConversation,
  required bool agentAttending,
  required int hour,
  required int openingHour,
  required int closingHour,
  required String welcomeMessage,
  required String awayMessage,
}) {
  if ([
        hour,
        openingHour,
        closingHour,
      ].any((value) => value < 0 || value > 23) ||
      openingHour == closingHour) {
    throw ArgumentError(
      'Las horas deben estar entre 0 y 23 y el horario debe tener una duración definida.',
    );
  }
  final trace = <String>['Mensaje entrante simulado'];
  if (agentAttending) {
    return DemoAutomationResult(null, null, [
      ...trace,
      'Un agente está atendiendo: el bot no interviene.',
    ]);
  }
  final withinHours = openingHour < closingHour
      ? hour >= openingHour && hour < closingHour
      : hour >= openingHour || hour < closingHour;
  trace.add(
    withinHours
        ? 'Dentro del horario configurado.'
        : 'Fuera del horario configurado.',
  );
  if (outOfHoursEnabled && !withinHours) {
    return DemoAutomationResult(DemoAutomation.outOfHours, awayMessage, [
      ...trace,
      'Prioridad 1: Fuera de horario coincide.',
      'Se detiene la evaluación: una sola respuesta.',
    ]);
  }
  trace.add(
    outOfHoursEnabled
        ? 'Prioridad 1: no coincide.'
        : 'Prioridad 1: regla desactivada.',
  );
  if (welcomeEnabled && isNewConversation) {
    return DemoAutomationResult(DemoAutomation.welcome, welcomeMessage, [
      ...trace,
      'Prioridad 2: Bienvenida coincide.',
      'Se detiene la evaluación: una sola respuesta.',
    ]);
  }
  return DemoAutomationResult(null, null, [
    ...trace,
    welcomeEnabled
        ? 'Prioridad 2: la conversación no es nueva.'
        : 'Prioridad 2: regla desactivada.',
    'Sin respuesta automática.',
  ]);
}

class AutomationDemo extends StatefulWidget {
  const AutomationDemo({super.key, required this.tenantName});
  final String tenantName;

  @override
  State<AutomationDemo> createState() => _AutomationDemoState();
}

class _AutomationDemoState extends State<AutomationDemo> {
  final _form = GlobalKey<FormState>();
  late final _welcome = TextEditingController(
    text:
        '¡Hola! Gracias por contactar a ${widget.tenantName}. '
        'Cuéntanos cómo podemos ayudarte y un asesor te atenderá.',
  );
  late final _away = TextEditingController(
    text:
        'Gracias por escribir a ${widget.tenantName}. En este momento '
        'estamos fuera de horario. Te responderemos en nuestra próxima jornada.',
  );
  final _message = TextEditingController(
    text: 'Hola, necesito información sobre sus servicios.',
  );
  bool _welcomeEnabled = true;
  bool _awayEnabled = true;
  bool _newConversation = true;
  bool _agentAttending = false;
  int _opening = 8;
  int _closing = 18;
  int _hour = 10;
  DemoAutomationResult? _result;
  String? _sentMessage;
  bool _testingPatient = false;

  @override
  void dispose() {
    _welcome.dispose();
    _away.dispose();
    _message.dispose();
    super.dispose();
  }

  void _invalidate() {
    _result = null;
    _sentMessage = null;
  }

  void _simulate() {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _sentMessage = _message.text.trim();
      _result = simulateAutomation(
        outOfHoursEnabled: _awayEnabled,
        welcomeEnabled: _welcomeEnabled,
        isNewConversation: _newConversation,
        agentAttending: _agentAttending,
        hour: _hour,
        openingHour: _opening,
        closingHour: _closing,
        welcomeMessage: _welcome.text.trim(),
        awayMessage: _away.text.trim(),
      );
    });
  }

  String _time(int value) => '${value.toString().padLeft(2, '0')}:00';

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF2FF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFCCE0FF)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LABORATORIO · DEMOSTRACIÓN',
                style: TextStyle(
                  color: Color(0xFF1765CE),
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Diseña una respuesta. Prueba la experiencia.',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'Sin conexión con Meta: no envía mensajes, no usa contactos reales '
                'ni modifica tu WhatsApp. Los cambios son temporales y se pierden '
                'al salir del módulo o cambiar de empresa.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () =>
                  setState(() => _testingPatient = !_testingPatient),
              icon: Icon(
                _testingPatient ? Icons.arrow_back : Icons.play_circle_outline,
              ),
              label: Text(
                _testingPatient
                    ? 'Volver a reglas de horario'
                    : 'Probar automatización',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_testingPatient)
          PatientAutomationDemo(
            key: ValueKey(widget.tenantName),
            tenantName: widget.tenantName,
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final rules = _rules();
              final preview = _preview();
              if (constraints.maxWidth < 1000) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [rules, const SizedBox(height: 20), preview],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: rules),
                  const SizedBox(width: 20),
                  Expanded(child: preview),
                ],
              );
            },
          ),
      ],
    ),
  );

  Widget _rules() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Reglas y recorrido',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      const Text(
        'Se ejecuta solo la primera regla que coincida. '
        'Fuera de horario tiene prioridad sobre bienvenida.',
      ),
      const SizedBox(height: 12),
      _step(
        Icons.chat_bubble_outline,
        '1. Recibir mensaje',
        'Solo mensajes escritos en este simulador.',
      ),
      _connector(),
      _step(
        Icons.support_agent,
        '2. Revisar atención humana',
        'Si un agente atiende, el bot se detiene.',
      ),
      _connector(),
      _rule(
        title: 'Fuera de horario',
        subtitle: 'Prioridad 1 · Horario diario de demostración',
        icon: Icons.schedule,
        enabled: _awayEnabled,
        controller: _away,
        onChanged: (value) => setState(() {
          _awayEnabled = value;
          _invalidate();
        }),
        extra: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _hourField('Apertura', _opening, (value) {
                    setState(() {
                      _opening = value;
                      _invalidate();
                    });
                  }),
                  _hourField('Cierre', _closing, (value) {
                    setState(() {
                      _closing = value;
                      _invalidate();
                    });
                  }),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Horario diario: ${_time(_opening)} a ${_time(_closing)}'
                '${_opening > _closing ? ' del día siguiente' : ''}. '
                'Se usa la hora elegida en la prueba, no el reloj real.',
              ),
              if (_opening == _closing)
                Text(
                  'Apertura y cierre deben ser diferentes.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      _connector(),
      _rule(
        title: 'Bienvenida',
        subtitle: 'Prioridad 2 · Solo conversaciones nuevas',
        icon: Icons.waving_hand_outlined,
        enabled: _welcomeEnabled,
        controller: _welcome,
        onChanged: (value) => setState(() {
          _welcomeEnabled = value;
          _invalidate();
        }),
      ),
      _connector(),
      _step(
        Icons.done_all,
        '3. Finalizar',
        'Una respuesta como máximo por prueba.',
      ),
    ],
  );

  Widget _connector() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4, horizontal: 22),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Icon(Icons.south, color: Colors.blueGrey),
    ),
  );

  Widget _step(IconData icon, String title, String subtitle) => Card(
    margin: EdgeInsets.zero,
    child: ListTile(
      leading: Icon(icon, color: const Color(0xFF1765CE)),
      title: Text(title),
      subtitle: Text(subtitle),
    ),
  );

  Widget _rule({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool enabled,
    required TextEditingController controller,
    required ValueChanged<bool> onChanged,
    Widget? extra,
  }) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(icon),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(subtitle),
            value: enabled,
            onChanged: onChanged,
          ),
          ?extra,
          TextFormField(
            controller: controller,
            minLines: 3,
            maxLines: 6,
            maxLength: 1000,
            decoration: InputDecoration(
              labelText: 'Respuesta de $title',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_invalidate),
            validator: (value) =>
                enabled && (value == null || value.trim().isEmpty)
                ? 'Escribe una respuesta para esta regla activa.'
                : null,
          ),
        ],
      ),
    ),
  );

  Widget _hourField(String label, int value, ValueChanged<int> onChanged) =>
      SizedBox(
        width: 150,
        child: DropdownButtonFormField<int>(
          initialValue: value,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          items: List.generate(
            24,
            (hour) => DropdownMenuItem(value: hour, child: Text(_time(hour))),
          ),
          onChanged: (hour) {
            if (hour != null) onChanged(hour);
          },
        ),
      );

  Widget _preview() => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Simulador de conversación',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text('Contacto ficticio · ${widget.tenantName}'),
          const SizedBox(height: 16),
          _hourField('Hora de prueba', _hour, (value) {
            setState(() {
              _hour = value;
              _invalidate();
            });
          }),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Conversación nueva'),
            value: _newConversation,
            onChanged: (value) => setState(() {
              _newConversation = value;
              _invalidate();
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Un agente está atendiendo'),
            value: _agentAttending,
            onChanged: (value) => setState(() {
              _agentAttending = value;
              _invalidate();
            }),
          ),
          TextFormField(
            controller: _message,
            minLines: 2,
            maxLines: 4,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Mensaje del cliente ficticio',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_invalidate),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Escribe un mensaje para simular.'
                : null,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _opening == _closing ? null : _simulate,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Simular mensaje'),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: _result == null
                ? const Text(
                    'Aquí aparecerá la conversación de prueba. '
                    'Cada simulación es independiente; no guarda historial.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _bubble('Cliente ficticio', _sentMessage!, false),
                      const SizedBox(height: 12),
                      if (_result!.response != null)
                        _bubble(
                          'Respuesta simulada · ${_result!.rule == DemoAutomation.welcome ? 'Bienvenida' : 'Fuera de horario'}',
                          _result!.response!,
                          true,
                        )
                      else
                        const Text(
                          'Sin respuesta automática.',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 20),
            const Text(
              'Recorrido de esta prueba',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final (index, step) in _result!.trace.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${index + 1}. $step'),
              ),
          ],
        ],
      ),
    ),
  );

  Widget _bubble(String label, String text, bool outbound) => Align(
    alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: outbound ? const Color(0xFFD8F3DE) : Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(text),
        ],
      ),
    ),
  );
}
