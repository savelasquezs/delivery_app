import 'dart:async';
import 'package:delivery_app/features/tracking/tracking_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('slow upload never blocks the next GPS capture', () async {
    final uploading = Completer<void>();
    var captures = 0;
    var uploads = 0;
    final scheduler = TrackingScheduler(
        capture: () async {
          captures++;
        },
        synchronize: () async {
          uploads++;
          await uploading.future;
        },
        onError: (_) {});
    final pending = scheduler.syncNow();
    await scheduler.captureNow();
    await scheduler.captureNow();
    await scheduler.syncNow();
    expect(captures, 2);
    expect(uploads, 1);
    uploading.complete();
    await pending;
    scheduler.close();
  });

  test('GPS timeout does not block synchronization; close prevents new cycles',
      () async {
    var uploads = 0;
    var errors = 0;
    final scheduler = TrackingScheduler(capture: () async {
      throw TimeoutException('GPS');
    }, synchronize: () async {
      uploads++;
    }, onError: (_) {
      errors++;
    });
    await scheduler.captureNow();
    await scheduler.syncNow();
    expect(errors, 1);
    expect(uploads, 1);
    scheduler.close();
    await scheduler.captureNow();
    await scheduler.syncNow();
    expect(errors, 1);
    expect(uploads, 1);
  });
}
