import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract class ApiConstants {
  static String get baseUrl =>
      dotenv.env['API_BASE_URL'] ?? 'https://senorarrozapi.up.railway.app/api';

  static String get signalrHubUrl =>
      dotenv.env['SIGNALR_HUB_URL'] ??
      'https://senorarrozapi.up.railway.app/hubs/orders';

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 15);

  // Auth
  static const String login = '/auth/login';
  static const String refresh = '/auth/refresh';
  static const String logout = '/auth/logout';

  // Orders delivery
  static const String deliveryAvailable = '/orders/delivery/available';
  static const String deliveryReady = '/orders/delivery/ready';
  static const String deliverySelfAssign = '/orders/delivery/self-assign';
  static String deliveryAssigned(int deliverymanId) =>
      '/orders/delivery/assigned/$deliverymanId';
  static String deliveryAssignedBranchSummary(int deliverymanId) =>
      '/orders/delivery/assigned/$deliverymanId/branch-summary';
  static String deliveryAssignedNeighborhoods(int deliverymanId) =>
      '/orders/delivery/assigned/$deliverymanId/neighborhoods';
  static String orderStatus(int orderId) => '/orders/$orderId/status';

  // Deliveryman
  static const String myDayState = '/deliverymen/me/day-state';

  // Dashboard
  static const String dashboardDeliveryMe = '/dashboard/delivery/me';
}
