import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract class ApiConstants {
  static String get baseUrl =>
      dotenv.env['API_BASE_URL'] ?? 'https://senorarrozapi.up.railway.app/api';

  static String get signalrHubUrl =>
      dotenv.env['SIGNALR_HUB_URL'] ??
      'https://senorarrozapi.up.railway.app/hubs/orders';

  /// Red móvil / API en frío (p. ej. Railway): más holgura que el front web (10s).
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // Auth
  static const String login = '/auth/login';
  static const String refresh = '/auth/refresh';
  static const String logout = '/auth/logout';
  static const String forgotPassword = '/auth/forgot-password';
  static const String authChangePassword = '/auth/change-password';

  static String userById(int id) => '/Users/$id';
  static String userProfile(int id) => '/Users/$id/profile';
  static String userProfileImage(int id) => '/Users/$id/profile-image';

  /// Origen del API sin sufijo `/api` (imágenes estáticas).
  static String get originUrl {
    final base = baseUrl;
    final i = base.toLowerCase().lastIndexOf('/api');
    if (i <= 0) return base;
    return base.substring(0, i);
  }

  // Orders delivery
  static const String deliveryAvailable = '/orders/delivery/available';
  static const String ordersSearch = '/orders/search';
  static const String deliveryReady = '/orders/delivery/ready';
  static const String deliverySelfAssign = '/orders/delivery/self-assign';
  static String deliveryAssigned(int deliverymanId) =>
      '/orders/delivery/assigned/$deliverymanId';
  static String deliveryAssignedBranchSummary(int deliverymanId) =>
      '/orders/delivery/assigned/$deliverymanId/branch-summary';
  static String deliveryAssignedNeighborhoods(int deliverymanId) =>
      '/orders/delivery/assigned/$deliverymanId/neighborhoods';
  static String orderStatus(int orderId) => '/orders/$orderId/status';
  static String orderWithDetails(int orderId) => '/orders/$orderId/details';

  // Customers (direcciones — mismo contrato que el front web)
  static const String customerNeighborhoods = '/customers/neighborhoods';
  static String customerAddress(int customerId, int addressId) =>
      '/customers/$customerId/addresses/$addressId';

  // Deliveryman
  static const String myDayState = '/deliverymen/me/day-state';
  static const String myAdvances = '/deliverymen/me/advances';
  static const String myDaySummary = '/deliverymen/me/day-summary';

  static String userPayrollInsights(int userId) =>
      '/Users/$userId/payroll-insights';
  static const String myDeviceToken = '/deliverymen/me/device-token';
  static const String deliverymanLocation = '/deliverymen/location';
  static String deliverymanLastLocation(int id) => '/deliverymen/$id/last-location';

  // Dashboard
  static const String dashboardDeliveryMe = '/dashboard/delivery/me';

  /// Cola de impresión térmica (ticket domicilio — mismo contrato que el front web).
  static String branchPrintJobs(int branchId) =>
      '/branches/$branchId/print-jobs';
}
