/// Evita dependencia circular entre [DioClient] y [AuthNotifier].
/// Se registra desde [AuthNotifier] al crearse y se limpia en [dispose].
void Function()? _onSessionInvalidatedByApi;

void setAuthSessionInvalidatedHandler(void Function()? handler) {
  _onSessionInvalidatedByApi = handler;
}

void notifyAuthSessionInvalidatedByApi() {
  _onSessionInvalidatedByApi?.call();
}
