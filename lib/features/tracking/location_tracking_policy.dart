import 'package:geolocator/geolocator.dart';

enum LocationFailureDisposition { discardPoint, retryPoint }

enum LocationTrackingIssue {
  none,
  gpsDisabled,
  permissionDenied,
  backgroundPermissionRequired,
  approximateLocation,
  unavailable,
}

/// Snapshot shared by the main isolate and the foreground-task isolate.
///
/// Background tracking is considered available only with precise location and
/// Android's `always` permission. Keeping this policy in one place prevents
/// the UI and the task handler from disagreeing about whether a point can be
/// sent while the app is in the background.
class LocationPermissionState {
  final bool serviceEnabled;
  final LocationPermission permission;
  final LocationAccuracyStatus accuracy;
  final bool readFailed;

  const LocationPermissionState({
    required this.serviceEnabled,
    required this.permission,
    required this.accuracy,
    this.readFailed = false,
  });

  bool get canTrackInBackground =>
      serviceEnabled &&
      permission == LocationPermission.always &&
      accuracy == LocationAccuracyStatus.precise;

  LocationTrackingIssue get issue {
    if (readFailed) return LocationTrackingIssue.unavailable;
    if (!serviceEnabled) return LocationTrackingIssue.gpsDisabled;
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return LocationTrackingIssue.permissionDenied;
    }
    if (accuracy == LocationAccuracyStatus.reduced) {
      return LocationTrackingIssue.approximateLocation;
    }
    if (permission != LocationPermission.always) {
      return LocationTrackingIssue.backgroundPermissionRequired;
    }
    return LocationTrackingIssue.none;
  }

  String get issueMessage {
    switch (issue) {
      case LocationTrackingIssue.none:
        return '';
      case LocationTrackingIssue.gpsDisabled:
        return 'Activa el GPS para continuar enviando tu ubicación.';
      case LocationTrackingIssue.permissionDenied:
        return 'Permite ubicación precisa “Todo el tiempo” en Ajustes de Android.';
      case LocationTrackingIssue.backgroundPermissionRequired:
        return 'Cambia el permiso de ubicación a “Todo el tiempo” en Ajustes de Android.';
      case LocationTrackingIssue.approximateLocation:
        return 'Cambia la ubicación aproximada a ubicación precisa en Ajustes de Android.';
      case LocationTrackingIssue.unavailable:
        return 'No se pudo comprobar el estado de ubicación. Revisa los permisos en Ajustes.';
    }
  }

  String get eventDetails =>
      'serviceEnabled=$serviceEnabled;permission=${permission.name};accuracy=${accuracy.name}'
      '${readFailed ? ';readFailed=true' : ''}';
}

Future<LocationPermissionState> readLocationPermissionState() async {
  try {
    return LocationPermissionState(
      serviceEnabled: await Geolocator.isLocationServiceEnabled(),
      permission: await Geolocator.checkPermission(),
      accuracy: await Geolocator.getLocationAccuracy(),
    );
  } catch (_) {
    return const LocationPermissionState(
      serviceEnabled: false,
      permission: LocationPermission.denied,
      accuracy: LocationAccuracyStatus.reduced,
      readFailed: true,
    );
  }
}

class TrackingServiceException implements Exception {
  final String message;

  const TrackingServiceException(this.message);

  @override
  String toString() => message;
}

/// An HTTP rejection must never stop the foreground location service.
///
/// Every failed point is queued for a later retry. This deliberately favors
/// at-least-once delivery over silently losing a worker location.
LocationFailureDisposition locationFailureDisposition(int? statusCode) {
  return LocationFailureDisposition.retryPoint;
}

bool shouldResumeActiveTracking({
  required int? previousWorkSessionId,
  required int workSessionId,
  required String? previousMode,
  required int? deliveryRouteId,
}) =>
    previousWorkSessionId == workSessionId &&
    (previousMode == 'active_delivery' || previousMode == 'ACTIVE_DELIVERY') &&
    deliveryRouteId != null;

double? validAccuracyMeters(double value) =>
    value.isFinite && value >= 0 ? value : null;

double? validHeadingDegrees(double value) =>
    value.isFinite && value >= 0 && value <= 360 ? value : null;
