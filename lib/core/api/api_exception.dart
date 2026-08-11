class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;

  factory ApiException.fromStatusCode(int statusCode, String? serverMessage) {
    final msg = serverMessage ?? _defaultMessage(statusCode);
    return ApiException(msg, statusCode: statusCode);
  }

  static String _defaultMessage(int code) => switch (code) {
        400 => 'Solicitud inválida',
        401 => 'Sesión expirada. Inicia sesión nuevamente',
        403 => 'No tienes permiso para realizar esta acción',
        404 => 'No encontramos la información solicitada',
        408 => 'La solicitud tardó demasiado. Inténtalo de nuevo',
        409 => 'Esta acción ya no está disponible en el estado actual',
        422 => 'Revisa la información e inténtalo de nuevo',
        429 => 'Has realizado demasiados intentos. Espera un momento',
        500 ||
        502 ||
        503 ||
        504 =>
          'El servicio no está disponible en este momento. Inténtalo más tarde',
        _ => 'No pudimos completar la acción. Inténtalo de nuevo',
      };
}
