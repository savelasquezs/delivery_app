enum LocationFailureDisposition { discardPoint, retryPoint }

/// An HTTP rejection must never stop the foreground location service.
///
/// Transient failures are queued for a later retry. Other client errors only
/// discard the rejected point, allowing the next scheduled capture to proceed.
LocationFailureDisposition locationFailureDisposition(int? statusCode) {
  if (statusCode == null ||
      statusCode == 401 ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500) {
    return LocationFailureDisposition.retryPoint;
  }
  return LocationFailureDisposition.discardPoint;
}

bool shouldResumeActiveTracking({
  required int? previousWorkSessionId,
  required int workSessionId,
  required String? previousMode,
  required int? deliveryRouteId,
}) =>
    previousWorkSessionId == workSessionId &&
    previousMode == 'ACTIVE_DELIVERY' &&
    deliveryRouteId != null;

double? validAccuracyMeters(double value) =>
    value.isFinite && value >= 0 ? value : null;

double? validHeadingDegrees(double value) =>
    value.isFinite && value >= 0 && value <= 360 ? value : null;
