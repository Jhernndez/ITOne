import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DemoAgenda extends StatefulWidget {
  const DemoAgenda({super.key, required this.tenantId, this.loadAgenda});

  final String tenantId;
  final Future<Map<String, dynamic>> Function(String tenantId)? loadAgenda;

  @override
  State<DemoAgenda> createState() => _DemoAgendaState();
}

class _DemoAgendaState extends State<DemoAgenda> {
  late Future<Map<String, dynamic>> _agenda = _load();

  Future<Map<String, dynamic>> _load() async {
    final loadAgenda = widget.loadAgenda;
    if (loadAgenda != null) return loadAgenda(widget.tenantId);
    final result = await Supabase.instance.client.rpc(
      'list_demo_agenda',
      params: {'p_tenant_id': widget.tenantId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  void _refresh() => setState(() => _agenda = _load());

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Agenda ficticia',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Actualizar agenda',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const Text(
            'Solo contiene datos ficticios. Los horarios se muestran en la zona horaria del dispositivo.',
          ),
          const SizedBox(height: 12),
          FutureBuilder<Map<String, dynamic>>(
            future: _agenda,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Text(
                  'No se pudo consultar la agenda: ${snapshot.error}',
                );
              }
              final data = snapshot.requireData;
              if (data['installed'] != true) {
                return const Text(
                  'Crea la demo de citas desde Automatizaciones para ver su agenda.',
                );
              }
              final appointments = (data['appointments'] as List)
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList();
              if (appointments.isEmpty) {
                return const Text('No hay horarios futuros.');
              }
              return Column(
                children: [
                  for (final appointment in appointments)
                    ListTile(
                      leading: const Icon(Icons.calendar_today_outlined),
                      title: Text(
                        '${DateTime.parse(appointment['starts_at'] as String).toLocal().toString().substring(0, 16)} · ${appointment['doctor']}',
                      ),
                      subtitle: Text(
                        appointment['patient'] == null
                            ? 'Disponible'
                            : '${appointment['patient']} · ${appointment['patient_code']}',
                      ),
                      trailing: Chip(
                        label: Text(appointment['status'] as String),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}
