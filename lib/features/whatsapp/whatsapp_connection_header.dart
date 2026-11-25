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
    final coexistence = configured && onboardingMode == 'coexistence';
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
                coexistence
                    ? 'WhatsApp de tu empresa'
                    : 'Conectar WhatsApp Business',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          coexistence
              ? 'Estado de la conexión: $statusLabel'
              : configured
              ? 'Estado de la conexión: requiere autorización'
              : 'Estado de la conexión: sin conectar',
        ),
        const Text(
          'El estado guardado no garantiza la entrega de mensajes. '
          'Si tienes problemas de conexión, contacta con soporte.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Conecta tu propio número para usar WhatsApp Business en el celular '
          'y en ITONE. Autoriza tu cuenta en la ventana de Meta; '
          'ITONE configura la conexión automáticamente, sujeto a elegibilidad '
          'y autorización de Meta. No necesitas copiar tokens ni identificadores.',
        ),
      ],
    );
  }
}
