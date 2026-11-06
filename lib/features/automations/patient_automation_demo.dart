import 'package:flutter/material.dart';

enum _Step { coverage, eps, service, exam, outcome, reason, human, finished }

class PatientAutomationDemo extends StatefulWidget {
  const PatientAutomationDemo({super.key, required this.tenantName});
  final String tenantName;

  @override
  State<PatientAutomationDemo> createState() => _PatientAutomationDemoState();
}

class _PatientAutomationDemoState extends State<PatientAutomationDemo> {
  final _input = TextEditingController();
  final List<({bool patient, String text})> _messages = [];
  final List<String> _trace = [];
  _Step _step = _Step.coverage;
  bool _eps = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _bot(String text) => _messages.add((patient: false, text: text));
  void _patient(String text) => _messages.add((patient: true, text: text));

  void _reset() {
    _messages.clear();
    _trace
      ..clear()
      ..add('Inicio de prueba IPS / Salud.');
    _step = _Step.coverage;
    _eps = false;
    _error = null;
    _input.clear();
    _bot(
      'Bienvenido a ${widget.tenantName}. ¿Tu solicitud es por EPS o particular?',
    );
  }

  void _coverage(bool eps) => setState(() {
    _eps = eps;
    _patient(eps ? 'EPS' : 'Particular');
    _trace.add(
      eps ? 'Rama EPS seleccionada.' : 'Rama particular seleccionada.',
    );
    _step = eps ? _Step.eps : _Step.service;
    _bot(
      eps
          ? 'Indica una EPS ficticia para esta prueba.'
          : '¿Qué servicio necesitas? Usa un ejemplo ficticio.',
    );
  });

  void _submit() {
    final value = _input.text.trim();
    if (value.isEmpty || value.length > 200) {
      setState(() => _error = 'Escribe entre 1 y 200 caracteres ficticios.');
      return;
    }
    setState(() {
      _patient(value);
      _input.clear();
      _error = null;
      switch (_step) {
        case _Step.eps:
          _trace.add('EPS de prueba recibida; no se valida cobertura.');
          _step = _Step.service;
          _bot('¿Qué servicio necesitas? Usa un ejemplo ficticio.');
        case _Step.service:
          _trace.add('Servicio de prueba recibido.');
          if (_eps) {
            _ready();
          } else {
            _step = _Step.exam;
            _bot(
              'Si tienes un examen médico relacionado, indica solo su nombre ficticio. '
              'También puedes continuar sin examen. No adjuntes documentos.',
            );
          }
        case _Step.exam:
          _trace.add(
            'Referencia ficticia de examen recibida; no se adjuntan archivos.',
          );
          _ready();
        case _Step.reason:
          _trace.add('Denegación simulada con motivo del agente.');
          _bot(
            'El agente ha denegado la solicitud. Motivo: $value\n'
            'No se ha confirmado ninguna cita. Puedes continuar con atención humana.',
          );
          _step = _Step.human;
        default:
          throw StateError('La etapa actual no admite texto.');
      }
    });
  }

  void _ready() {
    _step = _Step.outcome;
    _bot(
      'Datos ficticios recibidos. La solicitud queda pendiente de revisión; '
      'no se ha confirmado cobertura, tarifa ni cita.',
    );
    _trace.add('Solicitud simulada pendiente de revisión.');
  }

  void _outcome(String outcome) => setState(() {
    if (outcome == 'api') {
      _trace.add('Fallo de API inyectado; no se hizo ninguna llamada real.');
      _bot(
        'No fue posible consultar el sistema. Transferimos la solicitud a un agente '
        'en esta simulación, sin confirmar la solicitud ni una cita.',
      );
      _trace.add('Derivación humana simulada; no existe una asignación real.');
      _step = _Step.finished;
    } else if (outcome == 'deny') {
      _trace.add('El agente simulado revisa la solicitud.');
      _step = _Step.reason;
      _bot('Escribe el motivo ficticio que comunicará el agente.');
    } else {
      _trace.add('Fin de prueba: pendiente de revisión, sin confirmación.');
      _bot(
        'La prueba terminó con la solicitud pendiente. No se creó ninguna cita.',
      );
      _step = _Step.finished;
    }
  });

  bool get _acceptsText =>
      [_Step.eps, _Step.service, _Step.exam, _Step.reason].contains(_step);

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Probar automatización · IPS / Salud',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Conversación ficticia para demostración. No ingreses nombres de pacientes, '
            'documentos, resultados ni datos clínicos reales. No consulta APIs, no envía '
            'mensajes y no publica flujos. El historial se pierde al salir o reiniciar. '
            'Esta prueba es independiente de las reglas de horario del laboratorio.',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => setState(_reset),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reiniciar prueba'),
            ),
          ),
          for (final message in _messages)
            Align(
              alignment: message.patient
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                constraints: const BoxConstraints(maxWidth: 650),
                decoration: BoxDecoration(
                  color: message.patient
                      ? const Color(0xFFD8F3DE)
                      : const Color(0xFFEAF2FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.patient
                          ? 'Entrada de prueba'
                          : 'Automatización simulada',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(message.text),
                  ],
                ),
              ),
            ),
          if (_step == _Step.coverage)
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _coverage(true),
                  child: const Text('EPS'),
                ),
                FilledButton(
                  onPressed: () => _coverage(false),
                  child: const Text('Particular'),
                ),
              ],
            ),
          if (_acceptsText) ...[
            TextField(
              key: ValueKey(_step),
              controller: _input,
              maxLength: 200,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: switch (_step) {
                  _Step.eps => 'EPS ficticia',
                  _Step.service => 'Servicio requerido (ficticio)',
                  _Step.exam => 'Examen médico ficticio (opcional)',
                  _Step.reason => 'Motivo de denegación (ficticio)',
                  _ => '',
                },
                errorText: _error,
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _submit,
                  child: const Text('Continuar prueba'),
                ),
                if (_step == _Step.exam)
                  TextButton(
                    onPressed: () => setState(() {
                      _patient('No tengo examen médico.');
                      _input.clear();
                      _error = null;
                      _trace.add('Particular continúa sin examen médico.');
                      _ready();
                    }),
                    child: const Text('Continuar sin examen'),
                  ),
              ],
            ),
          ],
          if (_step == _Step.outcome) ...[
            const Text(
              'Elige el resultado que quieres demostrar:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _outcome('api'),
                  child: const Text('Simular fallo de API'),
                ),
                OutlinedButton(
                  onPressed: () => _outcome('deny'),
                  child: const Text('Agente deniega solicitud'),
                ),
                TextButton(
                  onPressed: () => _outcome('pending'),
                  child: const Text('Finalizar pendiente'),
                ),
              ],
            ),
          ],
          if (_step == _Step.human)
            FilledButton.icon(
              onPressed: () => setState(() {
                _patient('Continuar con un agente.');
                _bot(
                  'Te derivamos a atención humana en esta prueba. '
                  'No se asignó ningún agente real ni se confirmó la solicitud.',
                );
                _trace.add(
                  'Atención humana solicitada después de la denegación.',
                );
                _step = _Step.finished;
              }),
              icon: const Icon(Icons.support_agent),
              label: const Text('Continuar con atención humana'),
            ),
          if (_step == _Step.finished) ...[
            const SizedBox(height: 12),
            const Text(
              'Prueba finalizada · Sin cambios en sistemas reales.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
          const Divider(height: 32),
          const Text(
            'Recorrido del escenario',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final (index, step) in _trace.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${index + 1}. $step'),
            ),
        ],
      ),
    ),
  );
}
