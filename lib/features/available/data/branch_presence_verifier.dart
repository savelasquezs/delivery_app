import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

enum BranchPresenceStatus {
  initial,
  checking,
  inside,
  outside,
  branchLocationMissing,
  locationServicesDisabled,
  permissionDenied,
  permissionDeniedForever,
  locationUnavailable,
}

class BranchPresenceResult {
  final BranchPresenceStatus status;
  final double? latitude;
  final double? longitude;
  final double? distanceMeters;

  const BranchPresenceResult({
    required this.status,
    this.latitude,
    this.longitude,
    this.distanceMeters,
  });

  bool get isInside => status == BranchPresenceStatus.inside;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BranchPresenceResult &&
          status == other.status &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          distanceMeters == other.distanceMeters;

  @override
  int get hashCode => Object.hash(
        status,
        latitude,
        longitude,
        distanceMeters,
      );
}

class BranchPresenceVerifier {
  const BranchPresenceVerifier();

  Future<BranchPresenceResult> verify({
    required double? branchLatitude,
    required double? branchLongitude,
    required int allowedDistanceMeters,
  }) async {
    if (branchLatitude == null || branchLongitude == null) {
      return const BranchPresenceResult(
        status: BranchPresenceStatus.branchLocationMissing,
      );
    }

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const BranchPresenceResult(
          status: BranchPresenceStatus.locationServicesDisabled,
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return const BranchPresenceResult(
          status: BranchPresenceStatus.permissionDeniedForever,
        );
      }
      if (permission == LocationPermission.denied) {
        return const BranchPresenceResult(
          status: BranchPresenceStatus.permissionDenied,
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final distanceMeters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        branchLatitude,
        branchLongitude,
      );
      final radius = allowedDistanceMeters > 0 ? allowedDistanceMeters : 50;

      return BranchPresenceResult(
        status: distanceMeters <= radius
            ? BranchPresenceStatus.inside
            : BranchPresenceStatus.outside,
        latitude: position.latitude,
        longitude: position.longitude,
        distanceMeters: distanceMeters,
      );
    } catch (_) {
      return const BranchPresenceResult(
        status: BranchPresenceStatus.locationUnavailable,
      );
    }
  }
}

final branchPresenceVerifierProvider = Provider<BranchPresenceVerifier>((ref) {
  return const BranchPresenceVerifier();
});
