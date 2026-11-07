import 'package:flutter/material.dart';

class WhatsAppConnectionHeader extends StatelessWidget {
  const WhatsAppConnectionHeader({
    super.key,
    required this.configured,
    required this.onboardingMode,
    required this.statusLabel,
  });

  final bool configured;
  final String? onboardingMode;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final mode = onboardingMode == 'coexistence'
        ? 'Coexistencia'
        : onboardingMode == 'cloud_api'
        ? 'Conexión anterior Cloud API · sin coexistencia'
        : 'Modalidad por verificar';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.link_outlined,
              size: 32,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                configured ? 'WhatsApp · $mode' : 'Conectar WhatsApp Business',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Estado de la conexión en ITONE: $statusLabel'),
        const Text(
          'El estado guardado no certifica que Meta permita enviar mensajes '
          'ni que el número pueda usarse en el celular. Usa Validar conexión con Meta.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Coexistencia utiliza Cloud API para enviar y recibir mensajes. '
          'La opción de conexión con coexistencia permite solicitar el uso del '
          'mismo número en WhatsApp Business móvil y en ITONE, sujeto a elegibilidad '
          'y autorización de Meta. Los permisos y las credenciales se gestionan '
          'por empresa, exclusivamente en backend.',
        ),
      ],
    );
  }
}
