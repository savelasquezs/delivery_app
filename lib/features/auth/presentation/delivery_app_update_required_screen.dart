import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/version/delivery_app_version.dart';
import 'auth_notifier.dart';

class DeliveryAppUpdateRequiredScreen extends ConsumerWidget {
  const DeliveryAppUpdateRequiredScreen({super.key, this.policy});

  final DeliveryAppVersionPolicy? policy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePolicy = policy ?? ref.watch(authNotifierProvider).updatePolicy;
    final playStoreUrl = activePolicy?.playStoreUrl.isNotEmpty == true
        ? activePolicy!.playStoreUrl
        : kDeliveryAppPlayStoreUrl;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppTheme.spacingLg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.system_update_alt,
                      color: AppColors.primaryLight,
                      size: 72,
                    ),
                    const SizedBox(height: AppTheme.spacingLg),
                    Text(
                      'Actualización necesaria',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppTheme.spacingMd),
                    Text(
                      'Hay una nueva versión de Señor Arroz.\n'
                      'Actualiza la aplicación desde Google Play para continuar.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: AppTheme.spacingXl),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse(playStoreUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Actualizar en Google Play'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
