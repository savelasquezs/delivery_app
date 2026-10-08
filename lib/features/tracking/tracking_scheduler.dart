import 'dart:async';

/// GPS and network have independent in-flight guards. Each callback must be
/// bounded and handle its own domain errors; this guard also catches failures
/// in diagnostic storage so one failed tick cannot terminate the service.
class TrackingScheduler {
  final Future<void> Function() capture;
  final Future<void> Function() synchronize;
  final void Function(Object error) onError;
  bool _capturing = false;
  bool _uploading = false;
  bool _closed = false;
  TrackingScheduler(
      {required this.capture,
      required this.synchronize,
      required this.onError});

  Future<void> captureNow() async {
    if (_closed || _capturing) return;
    _capturing = true;
    try {
      await capture();
    } catch (error) {
      onError(error);
    } finally {
      _capturing = false;
    }
  }

  Future<void> syncNow() async {
    if (_closed || _uploading) return;
    _uploading = true;
    try {
      await synchronize();
    } catch (error) {
      onError(error);
    } finally {
      _uploading = false;
    }
  }

  void tick() {
    unawaited(captureNow());
    unawaited(syncNow());
  }

  void close() {
    _closed = true;
  }
}
