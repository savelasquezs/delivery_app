import '../version/delivery_app_version.dart';

/// Evita dependencia circular entre [DioClient] y [AuthNotifier].
/// Se registra desde [AuthNotifier] al crearse y se limpia en [dispose].
void Function(String? reason)? _onSessionInvalidatedByApi;
void Function()? _onWorkSessionChangedByPush;
void Function(DeliveryAppVersionPolicy policy)? _onDeliveryAppUpdateRequired;

void setAuthSessionInvalidatedHandler(void Function(String? reason)? handler) {
  _onSessionInvalidatedByApi = handler;
}

void notifyAuthSessionInvalidatedByApi([String? reason]) {
  _onSessionInvalidatedByApi?.call(reason);
}

void setWorkSessionChangedByPushHandler(void Function()? handler) {
  _onWorkSessionChangedByPush = handler;
}

void notifyWorkSessionChangedByPush() {
  _onWorkSessionChangedByPush?.call();
}

void setDeliveryAppUpdateRequiredHandler(
  void Function(DeliveryAppVersionPolicy policy)? handler,
) {
  _onDeliveryAppUpdateRequired = handler;
}

void notifyDeliveryAppUpdateRequired(DeliveryAppVersionPolicy policy) {
  _onDeliveryAppUpdateRequired?.call(policy);
}
