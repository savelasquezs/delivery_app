import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:signalr_netcore/ihub_protocol.dart';
import '../../core/api/api_constants.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/version/delivery_app_version.dart';

enum HubConnectionStatus { disconnected, connecting, connected, error }

class OrderHubService {
  HubConnection? _connection;
  HubConnectionStatus _status = HubConnectionStatus.disconnected;
  final SecureStorage _storage;
  final DeliveryAppVersionInfoLoader _versionInfo;

  final List<void Function(HubConnectionStatus)> _statusListeners = [];
  final List<void Function(String event, List<Object?>? args)> _eventListeners =
      [];

  OrderHubService(this._storage, this._versionInfo);

  HubConnectionStatus get status => _status;

  void addStatusListener(void Function(HubConnectionStatus) listener) {
    _statusListeners.add(listener);
  }

  void removeStatusListener(void Function(HubConnectionStatus) listener) {
    _statusListeners.remove(listener);
  }

  void addEventListener(void Function(String, List<Object?>?) listener) {
    _eventListeners.add(listener);
  }

  void removeEventListener(void Function(String, List<Object?>?) listener) {
    _eventListeners.remove(listener);
  }

  void _notifyStatus(HubConnectionStatus status) {
    _status = status;
    for (final listener in _statusListeners) {
      listener(status);
    }
  }

  /// [forceReconnect]: tras renovar el JWT en storage, hay que cerrar el hub y
  /// volver a negociar; si no, SignalR sigue usando el access token capturado al conectar.
  Future<void> connect(int branchId, {bool forceReconnect = false}) async {
    if (forceReconnect && _connection != null) {
      try {
        await _connection!.stop();
      } catch (_) {}
      _connection = null;
    }

    // No confiar solo en _status: tras background/kill puede quedar desincronizado.
    if (_connection?.state == HubConnectionState.Connected) {
      if (_status != HubConnectionStatus.connected) {
        _notifyStatus(HubConnectionStatus.connected);
      }
      return;
    }

    if (_connection?.state == HubConnectionState.Connecting ||
        _connection?.state == HubConnectionState.Reconnecting) {
      return;
    }

    if (_connection != null) {
      try {
        await _connection!.stop();
      } catch (_) {}
      _connection = null;
    }

    _notifyStatus(HubConnectionStatus.connecting);

    // Intentar primero con WebSockets, si falla hacer fallback a LongPolling
    final connected = await _tryConnect(
      transport: HttpTransportType.WebSockets,
    );
    if (!connected) {
      await _tryConnect(transport: HttpTransportType.LongPolling);
    }
  }

  Future<bool> _tryConnect({required HttpTransportType transport}) async {
    try {
      final headers = MessageHeaders();
      (await _versionInfo.headers()).forEach(headers.setHeaderValue);
      _connection = HubConnectionBuilder()
          .withUrl(
            ApiConstants.signalrHubUrl,
            options: HttpConnectionOptions(
              transport: transport,
              skipNegotiation: transport == HttpTransportType.WebSockets,
              accessTokenFactory: () async =>
                  (await _storage.getAuthToken()) ?? '',
              headers: headers,
            ),
          )
          .withAutomaticReconnect()
          .build();

      _connection!.onclose(({error}) {
        _notifyStatus(HubConnectionStatus.disconnected);
      });
      _connection!.onreconnecting(({error}) {
        _notifyStatus(HubConnectionStatus.connecting);
      });
      _connection!.onreconnected(({connectionId}) {
        _notifyStatus(HubConnectionStatus.connected);
      });

      _registerEvents();

      await _connection!.start();
      _notifyStatus(HubConnectionStatus.connected);
      return true;
    } catch (_) {
      await _connection?.stop();
      _connection = null;
      _notifyStatus(HubConnectionStatus.error);
      return false;
    }
  }

  /// Nombres alineados con `OrderNotificationService` (API): `OrderAssigned`.
  void _registerEvents() {
    for (final event in [
      'OrderReady',
      'OrderAssigned',
      'OrderAssignedToDelivery',
      'OrderModified',
      'OrderStatusChanged',
      'OrderCancelled',
      'DeliveryRoutingPlanChanged',
      'RouteProposalClaimed',
    ]) {
      _connection!.on(event, (args) {
        for (final listener in _eventListeners) {
          listener(event, args);
        }
      });
    }
  }

  Future<void> disconnect() async {
    await _connection?.stop();
    _connection = null;
    _notifyStatus(HubConnectionStatus.disconnected);
  }
}

final orderHubServiceProvider = Provider<OrderHubService>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return OrderHubService(
    storage,
    ref.watch(deliveryAppVersionInfoProvider),
  );
});
