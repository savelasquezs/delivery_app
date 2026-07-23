import 'package:delivery_app/features/tracking/location_tracking_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('locationFailureDisposition', () {
    test('keeps retryable failures for a later upload', () {
      for (final status in <int?>[null, 401, 408, 429, 500, 503]) {
        expect(
          locationFailureDisposition(status),
          LocationFailureDisposition.retryPoint,
        );
      }
    });

    test('discards one rejected point without stopping future captures', () {
      for (final status in <int>[400, 403, 404, 422]) {
        expect(
          locationFailureDisposition(status),
          LocationFailureDisposition.discardPoint,
        );
      }
    });
  });

  group('shouldResumeActiveTracking', () {
    test('resumes every 30-second tracking for the same route and session', () {
      for (final mode in <String>['active_delivery', 'ACTIVE_DELIVERY']) {
        expect(
          shouldResumeActiveTracking(
            previousWorkSessionId: 3,
            workSessionId: 3,
            previousMode: mode,
            deliveryRouteId: 2088,
          ),
          isTrue,
        );
      }
    });

    test('does not carry an old route into a different work session', () {
      expect(
        shouldResumeActiveTracking(
          previousWorkSessionId: 3,
          workSessionId: 4,
          previousMode: 'ACTIVE_DELIVERY',
          deliveryRouteId: 2088,
        ),
        isFalse,
      );
    });

    test('requires both active mode and a route', () {
      expect(
        shouldResumeActiveTracking(
          previousWorkSessionId: 3,
          workSessionId: 3,
          previousMode: 'LIGHT',
          deliveryRouteId: 2088,
        ),
        isFalse,
      );
      expect(
        shouldResumeActiveTracking(
          previousWorkSessionId: 3,
          workSessionId: 3,
          previousMode: 'ACTIVE_DELIVERY',
          deliveryRouteId: null,
        ),
        isFalse,
      );
    });
  });

  test('invalid optional GPS measurements are omitted', () {
    expect(validAccuracyMeters(-1), isNull);
    expect(validAccuracyMeters(double.nan), isNull);
    expect(validAccuracyMeters(4.2), 4.2);
    expect(validHeadingDegrees(-1), isNull);
    expect(validHeadingDegrees(361), isNull);
    expect(validHeadingDegrees(265.5), 265.5);
  });
}
