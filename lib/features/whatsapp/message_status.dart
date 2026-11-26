import 'package:flutter/material.dart';

class WhatsAppMessageStatus extends StatelessWidget {
  const WhatsAppMessageStatus({
    super.key,
    required this.timestamp,
    required this.outbound,
    required this.status,
  });
  final String? timestamp;
  final bool outbound;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(timestamp ?? '')?.toLocal();
    final time = date == null
        ? 'Hora no disponible'
        : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final (label, icon) = switch (status) {
      'read' => ('Leído', Icons.done_all),
      'delivered' => ('Entregado', Icons.done_all),
      'sent' => ('Enviado', Icons.done),
      'failed' => ('No entregado', Icons.error_outline),
      _ => ('Aceptado por Meta; pendiente de envío', Icons.schedule),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(time, style: Theme.of(context).textTheme.labelSmall),
        if (outbound) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: label,
            child: Icon(
              icon,
              size: 16,
              semanticLabel: label,
              color: status == 'read'
                  ? Colors.blue
                  : status == 'failed'
                  ? Theme.of(context).colorScheme.error
                  : Colors.grey,
            ),
          ),
        ],
      ],
    );
  }
}

List<Map<String, dynamic>> mergeWhatsAppMessage(
  List<Map<String, dynamic>> messages,
  Map<String, dynamic> incoming, {
  required bool deleted,
}) {
  final result = messages
      .where((message) => message['id'] != incoming['id'])
      .toList();
  if (!deleted) {
    final existing = messages
        .where((message) => message['id'] == incoming['id'])
        .firstOrNull;
    result.add({...?existing, ...incoming});
  }
  result.sort((a, b) {
    DateTime date(Map<String, dynamic> message) =>
        DateTime.tryParse(
          (message['provider_timestamp'] ?? message['created_at']) as String? ??
              '',
        ) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return date(a).compareTo(date(b));
  });
  return result;
}
