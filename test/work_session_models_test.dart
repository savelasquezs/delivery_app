import 'package:delivery_app/features/tracking/work_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses work session and confirmed tracking configuration', () {
    final session = DeliveryWorkSession.fromJson({
      'id': 12,
      'deliverymanId': 4,
      'branchId': 2,
      'deviceInstallationId': 'device-a',
      'status': 'active',
      'startedAt': '2026-07-20T18:00:00Z',
      'autoCloseAt': '2026-07-21T02:00:00Z',
      'lastCommunicationAt': '2026-07-20T18:00:00Z',
      'tracking': {
        'autoCloseTime': '21:00:00',
        'lightIntervalSeconds': 300,
        'activeIntervalSeconds': 30,
        'stayThresholdMinutes': 10,
        'stayRadiusMeters': 50,
        'allowedDistanceMeters': 50,
        'locationRetentionDays': 3,
        'incidentRetentionDays': 15,
      },
    });

    expect(session.isActive, isTrue);
    expect(session.autoCloseAt, DateTime.utc(2026, 7, 21, 2));
    expect(session.tracking.lightIntervalSeconds, 300);
    expect(session.tracking.activeIntervalSeconds, 30);
    expect(session.tracking.locationRetentionDays, 3);
    expect(session.tracking.incidentRetentionDays, 15);
  });
}
