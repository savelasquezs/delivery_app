class DeliveryTrackingConfiguration {
  final String autoCloseTime;
  final int lightIntervalSeconds;
  final int activeIntervalSeconds;
  final int stayThresholdMinutes;
  final int stayRadiusMeters;
  final int allowedDistanceMeters;
  final int locationRetentionDays;
  final int incidentRetentionDays;

  const DeliveryTrackingConfiguration({
    required this.autoCloseTime,
    required this.lightIntervalSeconds,
    required this.activeIntervalSeconds,
    required this.stayThresholdMinutes,
    required this.stayRadiusMeters,
    required this.allowedDistanceMeters,
    required this.locationRetentionDays,
    required this.incidentRetentionDays,
  });

  factory DeliveryTrackingConfiguration.fromJson(Map<String, dynamic> json) =>
      DeliveryTrackingConfiguration(
        autoCloseTime: json['autoCloseTime'] as String? ?? '21:00:00',
        lightIntervalSeconds: _positiveInt(json['lightIntervalSeconds'], 300),
        activeIntervalSeconds: _positiveInt(json['activeIntervalSeconds'], 30),
        stayThresholdMinutes: _positiveInt(json['stayThresholdMinutes'], 10),
        stayRadiusMeters: _positiveInt(json['stayRadiusMeters'], 50),
        allowedDistanceMeters: _positiveInt(json['allowedDistanceMeters'], 50),
        locationRetentionDays: _positiveInt(json['locationRetentionDays'], 3),
        incidentRetentionDays: _positiveInt(json['incidentRetentionDays'], 15),
      );

  Map<String, dynamic> toJson() => {
        'autoCloseTime': autoCloseTime,
        'lightIntervalSeconds': lightIntervalSeconds,
        'activeIntervalSeconds': activeIntervalSeconds,
        'stayThresholdMinutes': stayThresholdMinutes,
        'stayRadiusMeters': stayRadiusMeters,
        'allowedDistanceMeters': allowedDistanceMeters,
        'locationRetentionDays': locationRetentionDays,
        'incidentRetentionDays': incidentRetentionDays,
      };

  static int _positiveInt(dynamic value, int fallback) {
    final parsed = value is int ? value : (value is num ? value.toInt() : null);
    return parsed != null && parsed > 0 ? parsed : fallback;
  }
}

class DeliveryWorkSession {
  final int id;
  final int deliverymanId;
  final int branchId;
  final String deviceInstallationId;
  final String status;
  final DateTime startedAt;
  final DateTime autoCloseAt;
  final DateTime lastCommunicationAt;
  final DeliveryTrackingConfiguration tracking;

  const DeliveryWorkSession({
    required this.id,
    required this.deliverymanId,
    required this.branchId,
    required this.deviceInstallationId,
    required this.status,
    required this.startedAt,
    required this.autoCloseAt,
    required this.lastCommunicationAt,
    required this.tracking,
  });

  bool get isActive => status.toLowerCase() == 'active';

  factory DeliveryWorkSession.fromJson(Map<String, dynamic> json) =>
      DeliveryWorkSession(
        id: (json['id'] as num).toInt(),
        deliverymanId: (json['deliverymanId'] as num).toInt(),
        branchId: (json['branchId'] as num).toInt(),
        deviceInstallationId: json['deviceInstallationId'] as String? ?? '',
        status: json['status'] as String? ?? '',
        startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
        autoCloseAt: DateTime.parse(json['autoCloseAt'] as String).toUtc(),
        lastCommunicationAt:
            DateTime.parse(json['lastCommunicationAt'] as String).toUtc(),
        tracking: DeliveryTrackingConfiguration.fromJson(
          Map<String, dynamic>.from(json['tracking'] as Map),
        ),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'deliverymanId': deliverymanId,
        'branchId': branchId,
        'deviceInstallationId': deviceInstallationId,
        'status': status,
        'startedAt': startedAt.toIso8601String(),
        'autoCloseAt': autoCloseAt.toIso8601String(),
        'lastCommunicationAt': lastCommunicationAt.toIso8601String(),
        'tracking': tracking.toJson(),
      };
}
