import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/api/api_constants.dart';
import '../../core/api/dio_client.dart';

/// Handler para mensajes en background (debe estar en nivel top-level o static).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // El sistema operativo ya muestra la notificación cuando la app está en background/killed.
  // Aquí podemos hacer procesamiento extra si fuera necesario.
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

    // Registrar handler de background antes de todo
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

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

  // Muestra la notificación en foreground usando flutter_local_notifications
  static void _showForegroundNotification(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;

    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
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
      ),
    );
  }
}

