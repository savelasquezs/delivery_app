/// Evita dependencia circular entre [DioClient] y [AuthNotifier].
/// Se registra desde [AuthNotifier] al crearse y se limpia en [dispose].
void Function()? _onSessionInvalidatedByApi;
void Function()? _onWorkSessionChangedByPush;

void setAuthSessionInvalidatedHandler(void Function()? handler) {
  _onSessionInvalidatedByApi = handler;
}

void notifyAuthSessionInvalidatedByApi() {
  _onSessionInvalidatedByApi?.call();
}

void setWorkSessionChangedByPushHandler(void Function()? handler) {
  _onWorkSessionChangedByPush = handler;
}

void notifyWorkSessionChangedByPush() {
  _onWorkSessionChangedByPush?.call();
}
