import '../version/delivery_app_version.dart';

/// Resultado de intentar renovar el access token con el refresh guardado.
sealed class RefreshAccessResult {
  const RefreshAccessResult();
}

/// Credenciales válidas y persistidas en el almacenamiento de sesión.
final class RefreshAccessSuccess extends RefreshAccessResult {
  const RefreshAccessSuccess(this.token);
  final String token;
}

/// Refresh inválido o revocado: almacenamiento de sesión limpiado.
final class RefreshAccessSessionEnded extends RefreshAccessResult {
  const RefreshAccessSessionEnded();
}

/// Red, timeout o respuesta inesperada: no se cierra sesión local.
final class RefreshAccessTransientFailure extends RefreshAccessResult {
  const RefreshAccessTransientFailure();
}

final class RefreshAccessUpdateRequired extends RefreshAccessResult {
  const RefreshAccessUpdateRequired(this.policy);
  final DeliveryAppVersionPolicy policy;
}

/// The caller belongs to an older login. Do not clear the newer session.
final class RefreshAccessSessionChanged extends RefreshAccessResult {
  const RefreshAccessSessionChanged();
}
