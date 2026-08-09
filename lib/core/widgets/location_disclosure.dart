import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';

const locationDisclosureText =
    'Señor Arroz recopila tu ubicación precisa durante tu jornada laboral, '
    'incluso cuando la aplicación está cerrada o no está en uso, para gestionar '
    'los domicilios, registrar tu recorrido y verificar la correcta prestación '
    'del servicio. La ubicación se conserva y sincroniza durante la jornada '
    'laboral y el seguimiento finaliza al cerrar la jornada.';

final _privacyPolicyUri = Uri.parse(
  'https://senorarroz.up.railway.app/privacy-policy.html',
);

Future<bool> showLocationDisclosure(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Seguimiento de ubicación'),
      content: const SingleChildScrollView(
        child: Text(locationDisclosureText),
      ),
      actions: [
        TextButton(
          onPressed: () => launchUrl(
            _privacyPolicyUri,
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('Política de privacidad'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Continuar'),
        ),
      ],
    ),
  );
  return result == true;
}
