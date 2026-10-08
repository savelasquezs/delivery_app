import 'package:delivery_app/features/tracking/location_tracking_policy.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('locationFailureDisposition', () {
    test('keeps retryable failures for a later upload', () {
      for (final status in <int?>[null, 401, 403, 404, 408, 429, 500, 503]) {
        expect(
          locationFailureDisposition(status),
          LocationFailureDisposition.retryPoint,
        );
      }
    });

    test('quarantines invalid points without silently deleting them', () {
      for (final status in <int>[400, 422]) {
        expect(
          locationFailureDisposition(status),
          LocationFailureDisposition.quarantinePoint,
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

  group('LocationPermissionState', () {
    test('allows background tracking only with always and precise', () {
      const state = LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.precise,
      );

      expect(state.canTrackInBackground, isTrue);
      expect(state.issue, LocationTrackingIssue.none);
      expect(state.issueMessage, isEmpty);
    });

    test('rejects while-in-use and approximate permissions', () {
      const whileInUse = LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.whileInUse,
        accuracy: LocationAccuracyStatus.precise,
      );
      const approximate = LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.reduced,
      );

      expect(whileInUse.canTrackInBackground, isFalse);
      expect(
          whileInUse.issue, LocationTrackingIssue.backgroundPermissionRequired);
      expect(approximate.canTrackInBackground, isFalse);
      expect(approximate.issue, LocationTrackingIssue.approximateLocation);
    });

    test('reports disabled GPS and permission denial separately', () {
      const gpsDisabled = LocationPermissionState(
        serviceEnabled: false,
        permission: LocationPermission.always,
        accuracy: LocationAccuracyStatus.precise,
      );
      const denied = LocationPermissionState(
        serviceEnabled: true,
        permission: LocationPermission.deniedForever,
        accuracy: LocationAccuracyStatus.precise,
      );

      expect(gpsDisabled.issue, LocationTrackingIssue.gpsDisabled);
      expect(denied.issue, LocationTrackingIssue.permissionDenied);
      expect(denied.eventDetails, contains('permission=deniedForever'));
    });
  });
}
