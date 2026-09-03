import 'package:delivery_app/features/home/home_resume_policy.dart';
import 'package:delivery_app/features/tracking/work_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('solo sincroniza la pestaña operativa activa al reanudar', () {
    expect(homeResumeRefreshForTab(0), HomeResumeRefresh.available);
    expect(homeResumeRefreshForTab(1), HomeResumeRefresh.route);
    expect(homeResumeRefreshForTab(2), HomeResumeRefresh.none);
    expect(homeResumeRefreshForTab(3), HomeResumeRefresh.none);
  });

  group('SignalR de pedidos', () {
    final now = DateTime.utc(2026, 9, 2, 15);

    test('solo conecta con jornada activa y vigente', () {
      expect(
        shouldConnectOrderHub(
          authenticated: true,
          workSession: _session(autoCloseAt: now.add(const Duration(hours: 1))),
          nowUtc: now,
        ),
        isTrue,
      );
      expect(
        shouldConnectOrderHub(
          authenticated: true,
          workSession: _session(
            status: 'closed',
            autoCloseAt: now.add(const Duration(hours: 1)),
          ),
          nowUtc: now,
        ),
        isFalse,
      );
      expect(
        shouldConnectOrderHub(
          authenticated: true,
          workSession: _session(autoCloseAt: now),
          nowUtc: now,
        ),
        isFalse,
      );
      expect(
        shouldConnectOrderHub(
          authenticated: false,
          workSession: _session(autoCloseAt: now.add(const Duration(hours: 1))),
          nowUtc: now,
        ),
        isFalse,
      );
      expect(
        shouldConnectOrderHub(
          authenticated: true,
          workSession: null,
          nowUtc: now,
        ),
        isFalse,
      );
    });
  });
}

DeliveryWorkSession _session({
  String status = 'active',
  required DateTime autoCloseAt,
}) {
  return DeliveryWorkSession(
    id: 1,
    deliverymanId: 2,
    branchId: 3,
    deviceInstallationId: 'device',
    status: status,
    startedAt: autoCloseAt.subtract(const Duration(hours: 1)),
    autoCloseAt: autoCloseAt,
    lastCommunicationAt: autoCloseAt.subtract(const Duration(minutes: 1)),
    tracking: const DeliveryTrackingConfiguration(
      autoCloseTime: '21:00:00',
      lightIntervalSeconds: 300,
      activeIntervalSeconds: 30,
      stayThresholdMinutes: 10,
      stayRadiusMeters: 50,
      allowedDistanceMeters: 50,
      locationRetentionDays: 3,
      incidentRetentionDays: 15,
    ),
  );
}
