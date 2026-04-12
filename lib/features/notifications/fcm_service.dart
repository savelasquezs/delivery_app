import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/api/api_constants.dart';
import '../../core/api/dio_client.dart';

(String? title, String? body) _titleBodyFromRemoteMessage(RemoteMessage message) {
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

NotificationDetails _notificationDetails() {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      _orderChannel.id,
      _orderChannel.name,
      channelDescription: _orderChannel.description,
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
  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
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

  final (title, body) = _titleBodyFromRemoteMessage(message);
  if (title == null && body == null) {
    debugPrint('FCM background: sin título ni cuerpo, no se muestra');
    return;
  }

  final id = _notificationId(message);
  await plugin.show(id, title, body, _notificationDetails());
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

class FcmService {
  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Inicializa Firebase + FCM + canal local. Llamar desde `main()` antes de `runApp`.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Canal Android de alta prioridad
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_orderChannel);

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
      final androidImpl = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidImpl?.requestNotificationsPermission();
      debugPrint(
        'FCM: flutter_local_notifications requestNotificationsPermission => $granted',
      );
    }

    // Escuchar mensajes FOREGROUND (cuando la app está abierta)
    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
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
    final token = await getToken();
    if (token == null) return;
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
    if (token == null) return;
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

  static void _showForegroundNotification(RemoteMessage message) {
    debugPrint(
      'FCM onMessage: messageId=${message.messageId} dataKeys=${message.data.keys.join(",")}',
    );
    final (title, body) = _titleBodyFromRemoteMessage(message);
    if (title == null && body == null) {
      debugPrint('FCM onMessage: sin título ni cuerpo');
      return;
    }

    final id = _notificationId(message);
    unawaited(
      _localNotifications
          .show(id, title, body, _notificationDetails())
          .then(
            (_) => debugPrint('FCM onMessage: local notification show ok id=$id'),
            onError: (Object e, StackTrace st) =>
                debugPrint('FCM onMessage: error mostrando notificación: $e'),
          ),
    );
  }
}
