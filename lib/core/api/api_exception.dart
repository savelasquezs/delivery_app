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
        404 => 'Recurso no encontrado',
        409 => 'Conflicto con el estado actual',
        422 => 'Datos inválidos',
        500 => 'Error interno del servidor',
        _ => 'Error desconocido (código $code)',
      };
}
