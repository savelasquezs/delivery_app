import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_constants.dart';
import '../../core/api/dio_client.dart';
import '../../core/auth/auth_session_bridge.dart';
import '../tracking/location_tracking_service.dart';

(String? title, String? body) _titleBodyFromRemoteMessage(
    RemoteMessage message) {
  final n = message.notification;
  var title = n?.title ?? message.data['title'];
  var body = n?.body ?? message.data['body'];
  if (title != null && title.isEmpty) title = null;
  if (body != null && body.isEmpty) body = null;
  return (title, body);
}

int _notificationId(RemoteMessage message) {
  final mid = message.messageId;
  if (mid != null && mid.isNotEmpty) return mid.hashCode;
  final t = message.sentTime?.millisecondsSinceEpoch;
  if (t != null) return t % 2147483647;
  return DateTime.now().millisecondsSinceEpoch % 2147483647;
}

NotificationDetails _notificationDetailsForData(Map<String, dynamic> data) {
  final channel = data['type'] == DeliveryTrackingReviewNotice.type
      ? _trackingReviewChannel
      : _orderChannel;
  return NotificationDetails(
    android: AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      icon: '@mipmap/ic_launcher',
    ),
    iOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );
}

/// Handler para mensajes en background (debe estar en nivel top-level o static).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await FcmService.handleTrackingReviewData(message.data, notifyUi: false);
  await _applyWorkSessionCommand(message.data, notifyUi: false);
  debugPrint(
    'FCM background: messageId=${message.messageId} hasNotification=${message.notification != null} dataKeys=${message.data.keys.join(",")}',
  );

  if (message.notification != null) {
    debugPrint(
      'FCM background: omitiendo show local (el SO ya muestra notification + data).',
    );
    return;
  }

  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  await plugin.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
  );
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_orderChannel);
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_trackingReviewChannel);

  final (title, body) = _titleBodyFromRemoteMessage(message);
  if (title == null && body == null) {
    debugPrint('FCM background: sin título ni cuerpo, no se muestra');
    return;
  }

  final id = _notificationId(message);
  await plugin.show(
    id,
    title,
    body,
    _notificationDetailsForData(message.data),
  );
  debugPrint('FCM background: notificación local mostrada id=$id');
}

/// Canal de notificaciones para Android (alta prioridad).
const AndroidNotificationChannel _orderChannel = AndroidNotificationChannel(
  'delivery_orders',
  'Pedidos de domicilio',
  description: 'Avisos de nuevos pedidos listos para entrega',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

const AndroidNotificationChannel _trackingReviewChannel =
    AndroidNotificationChannel(
  'delivery_tracking_reviews',
  'Revisiones de seguimiento',
  description: 'Avisos importantes sobre el seguimiento durante la jornada',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

class DeliveryTrackingReviewNotice {
  static const type = 'delivery_tracking_review';

  final int alertId;
  final int deliverymanId;
  final String alertType;
  final String title;
  final String body;

  const DeliveryTrackingReviewNotice({
    required this.alertId,
    required this.deliverymanId,
    required this.alertType,
    required this.title,
    required this.body,
  });

  factory DeliveryTrackingReviewNotice.fromJson(Map<String, dynamic> json) =>
      DeliveryTrackingReviewNotice(
        alertId: int.parse(json['alertId'].toString()),
        deliverymanId: int.parse(json['deliverymanId'].toString()),
        alertType: json['alertType'].toString(),
        title: json['title'].toString(),
        body: json['body'].toString(),
      );

  static DeliveryTrackingReviewNotice? fromData(
    Map<String, dynamic> data,
  ) {
    if (data['type']?.toString() != type) return null;
    final alertId = int.tryParse(data['alertId']?.toString() ?? '');
    final deliverymanId = int.tryParse(data['deliverymanId']?.toString() ?? '');
    final alertType = data['alertType']?.toString().trim() ?? '';
    final title = data['title']?.toString().trim() ?? '';
    final body = data['body']?.toString().trim() ?? '';
    if (alertId == null ||
        deliverymanId == null ||
        alertType.isEmpty ||
        title.isEmpty ||
        body.isEmpty) {
      return null;
    }
    return DeliveryTrackingReviewNotice(
      alertId: alertId,
      deliverymanId: deliverymanId,
      alertType: alertType,
      title: title,
      body: body,
    );
  }

  Map<String, dynamic> toJson() => {
        'alertId': alertId,
        'deliverymanId': deliverymanId,
        'alertType': alertType,
        'title': title,
        'body': body,
      };
}

class FcmService {
  static const _pendingTrackingReviewKey =
      'delivery_tracking_review_pending_notices';
  static const _handledTrackingReviewKey =
      'delivery_tracking_review_handled_alert_ids';
  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static final _trackingReviewController =
      StreamController<DeliveryTrackingReviewNotice>.broadcast();
  static bool _initialized = false;
  static DioClient? _authenticatedClient;
  static StreamSubscription<String>? _tokenRefreshSubscription;

  static Stream<DeliveryTrackingReviewNotice> get trackingReviewNotices =>
      _trackingReviewController.stream;

  /// Inicializa Firebase + FCM + canal local. Llamar desde `main()` antes de `runApp`.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Canal Android de alta prioridad
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_orderChannel);
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_trackingReviewChannel);

    // Configuración local notifications
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );

    // Android 13+: permiso para mostrar notificaciones locales (FCM en foreground usa este plugin).
    if (Platform.isAndroid) {
      final androidImpl =
          _localNotifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidImpl?.requestNotificationsPermission();
      debugPrint(
        'FCM: flutter_local_notifications requestNotificationsPermission => $granted',
      );
    }

    // Escuchar mensajes FOREGROUND (cuando la app está abierta)
    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      unawaited(_applyWorkSessionCommand(message.data));
      unawaited(handleTrackingReviewData(message.data));
    });
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      await _applyWorkSessionCommand(initialMessage.data);
      await handleTrackingReviewData(initialMessage.data);
    }
  }

  static Future<void> handleTrackingReviewData(
    Map<String, dynamic> data, {
    bool notifyUi = true,
  }) async {
    final notice = DeliveryTrackingReviewNotice.fromData(data);
    if (notice == null) return;
    final preferences = await SharedPreferences.getInstance();
    final handled = preferences.getStringList(_handledTrackingReviewKey) ?? [];
    if (handled.contains(notice.alertId.toString())) return;
    final pending = await pendingTrackingReviewNotices();
    if (!pending.any((item) => item.alertId == notice.alertId)) {
      pending.add(notice);
      await _savePendingTrackingReviewNotices(pending);
    }
    if (notifyUi) _trackingReviewController.add(notice);
  }

  static Future<List<DeliveryTrackingReviewNotice>>
      pendingTrackingReviewNotices() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_pendingTrackingReviewKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((item) => DeliveryTrackingReviewNotice.fromJson(
                Map<String, dynamic>.from(item as Map),
              ))
          .toList();
    } catch (_) {
      await preferences.remove(_pendingTrackingReviewKey);
      return [];
    }
  }

  static Future<void> emitPendingTrackingReviewNotices() async {
    for (final notice in await pendingTrackingReviewNotices()) {
      _trackingReviewController.add(notice);
    }
  }

  static Future<void> dismissTrackingReviewNotice(int alertId) async {
    final pending = await pendingTrackingReviewNotices();
    pending.removeWhere((notice) => notice.alertId == alertId);
    await _savePendingTrackingReviewNotices(pending);
    final preferences = await SharedPreferences.getInstance();
    final handled = preferences.getStringList(_handledTrackingReviewKey) ?? [];
    handled.remove(alertId.toString());
    handled.add(alertId.toString());
    await preferences.setStringList(
      _handledTrackingReviewKey,
      handled.length <= 100 ? handled : handled.sublist(handled.length - 100),
    );
  }

  static Future<void> clearTrackingReviewNotices() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_pendingTrackingReviewKey);
    await preferences.remove(_handledTrackingReviewKey);
  }

  static Future<void> _savePendingTrackingReviewNotices(
    List<DeliveryTrackingReviewNotice> notices,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    if (notices.isEmpty) {
      await preferences.remove(_pendingTrackingReviewKey);
      return;
    }
    await preferences.setString(
      _pendingTrackingReviewKey,
      jsonEncode(notices.map((notice) => notice.toJson()).toList()),
    );
  }

  /// Solicita permiso push (Android 13+ / iOS).
  static Future<bool> requestPermission() async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  /// Obtiene el token FCM actual.
  static Future<String?> getToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('FCM: error obteniendo token: $e');
      return null;
    }
  }

  /// Registra el token en el backend.
  static Future<void> registerToken(DioClient client) async {
    _authenticatedClient = client;
    _listenForTokenRefresh();
    final token = await getToken();
    if (token == null) return;
    await _registerKnownToken(client, token);
  }

  static void _listenForTokenRefresh() {
    if (_tokenRefreshSubscription != null) return;
    _tokenRefreshSubscription =
        FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) {
        final client = _authenticatedClient;
        if (client == null) return;
        unawaited(_registerKnownToken(client, token));
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('FCM: error renovando token: $error');
      },
    );
  }

  static Future<void> _registerKnownToken(
    DioClient client,
    String token,
  ) async {
    try {
      await client.post<void>(
        ApiConstants.myDeviceToken,
        data: {
          'token': token,
          'platform': Platform.isIOS ? 'ios' : 'android',
        },
      );
      debugPrint('FCM: token registrado en backend');
    } catch (e) {
      debugPrint('FCM: error registrando token: $e');
    }
  }

  /// Elimina el token del backend (al cerrar sesión).
  static Future<void> unregisterToken(DioClient client) async {
    final token = await getToken();
    if (token != null) {
      try {
        await client.delete<void>(
          ApiConstants.myDeviceToken,
          data: {'token': token},
        );
        debugPrint('FCM: token eliminado del backend');
      } catch (e) {
        debugPrint('FCM: error eliminando token: $e');
      }
    }
    _authenticatedClient = null;
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
  }

  static void _showForegroundNotification(RemoteMessage message) {
    debugPrint(
      'FCM onMessage: messageId=${message.messageId} dataKeys=${message.data.keys.join(",")}',
    );
    unawaited(handleTrackingReviewData(message.data));
    unawaited(_applyWorkSessionCommand(message.data));
    final (title, body) = _titleBodyFromRemoteMessage(message);
    if (title == null && body == null) {
      debugPrint('FCM onMessage: sin título ni cuerpo');
      return;
    }

    final id = _notificationId(message);
    unawaited(
      _localNotifications
          .show(
            id,
            title,
            body,
            _notificationDetailsForData(message.data),
          )
          .then(
            (_) =>
                debugPrint('FCM onMessage: local notification show ok id=$id'),
            onError: (Object e, StackTrace st) =>
                debugPrint('FCM onMessage: error mostrando notificación: $e'),
          ),
    );
  }
}

Future<void> _applyWorkSessionCommand(
  Map<String, dynamic> data, {
  bool notifyUi = true,
}) async {
  final type = data['type']?.toString();
  if (type == 'work_session_closed') {
    await LocationTrackingService.stopTracking();
    if (notifyUi) notifyAuthSessionInvalidatedByApi();
    return;
  }

  if (type != 'work_session_updated') return;
  final autoCloseAt = DateTime.tryParse(data['autoCloseAt']?.toString() ?? '');
  if (autoCloseAt == null) return;
  await LocationTrackingService.updateAutoCloseAt(autoCloseAt);
  if (notifyUi) notifyWorkSessionChangedByPush();
}
