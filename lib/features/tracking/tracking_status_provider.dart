import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tracking_outbox.dart';

/// Local reads only: observing tracking health never polls the HTTP API.
final trackingSnapshotProvider = StreamProvider.autoDispose
    .family<TrackingSnapshot, int>((ref, sessionId) async* {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final outbox = TrackingOutbox.shared;
  while (!disposed) {
    try {
      final context = await outbox.current();
      if (context == null || context.workSessionId != sessionId) {
        yield const TrackingSnapshot(
            uploadIssue: 'El seguimiento no está activo');
      } else {
        yield await outbox.snapshot(context);
      }
    } catch (_) {
      yield const TrackingSnapshot(
          uploadIssue: 'No se pudo comprobar el último envío');
    }
    await Future<void>.delayed(const Duration(seconds: 15));
  }
});
