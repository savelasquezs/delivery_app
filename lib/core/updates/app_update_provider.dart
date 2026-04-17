import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_update_checker.dart';
import 'delivery_app_release_manifest.dart';

final appUpdateCheckerProvider = Provider<AppUpdateChecker>((ref) {
  return AppUpdateChecker();
});

/// Resultado cacheado hasta [invalidate]; conviene invalidar al volver a primer plano.
final appUpdateCheckProvider =
    FutureProvider<AppUpdateCheckResult?>((ref) async {
  return ref.watch(appUpdateCheckerProvider).check();
});
