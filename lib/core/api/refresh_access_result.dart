/// Resultado de intentar renovar el access token con el refresh guardado.
sealed class RefreshAccessResult {
  const RefreshAccessResult();
}

/// Renovación correcta; los tokens ya están persistidos en [DioClient].
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
