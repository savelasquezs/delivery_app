enum LocationFailureDisposition { discardPoint, retryPoint }

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
