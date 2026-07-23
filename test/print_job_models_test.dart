import 'dart:async';

import 'package:delivery_app/features/orders/models/print_job_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EnqueuePrintJobResult interpreta jobId camelCase y PascalCase', () {
    expect(
      EnqueuePrintJobResult.fromJson({'jobId': 123}).jobId,
      123,
    );
    expect(
      EnqueuePrintJobResult.fromJson({'JobId': 456}).jobId,
      456,
    );
  });

  test('PrintJobStatusResult interpreta los cuatro estados seguros', () {
    for (final status in PrintJobStatus.values) {
      final result = PrintJobStatusResult.fromJson({
        'jobId': 1,
        'status': status.name,
        'kind': 'delivery',
        'createdAt': '2026-07-23T12:00:00Z',
        'startedAt': null,
        'completedAt': null,
        'errorMessage': null,
      });
      expect(result.status, status);
      expect(result.kind, 'delivery');
    }
  });

  test('PrintJobRequestCoordinator comparte una solicitud en vuelo', () async {
    final coordinator = PrintJobRequestCoordinator();
    final completer = Completer<EnqueuePrintJobResult>();
    var calls = 0;

    Future<EnqueuePrintJobResult> request() {
      calls++;
      return completer.future;
    }

    final first = coordinator.run('1:99', request);
    final second = coordinator.run('1:99', request);
    expect(identical(first, second), isTrue);
    expect(calls, 1);

    completer.complete(const EnqueuePrintJobResult(jobId: 77));
    expect((await first).jobId, 77);
    expect((await second).jobId, 77);
  });

  test('PrintJobRequestCoordinator libera la clave después de un error',
      () async {
    final coordinator = PrintJobRequestCoordinator();
    var calls = 0;

    Future<EnqueuePrintJobResult> request() async {
      calls++;
      if (calls == 1) throw StateError('api');
      return const EnqueuePrintJobResult(jobId: 2);
    }

    await expectLater(coordinator.run('1:2', request), throwsStateError);
    final result = await coordinator.run('1:2', request);

    expect(calls, 2);
    expect(result.jobId, 2);
  });
}
