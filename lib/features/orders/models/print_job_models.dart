class EnqueuePrintJobResult {
  final int jobId;

  const EnqueuePrintJobResult({required this.jobId});

  factory EnqueuePrintJobResult.fromJson(Map<String, dynamic> json) {
    final value = json['jobId'] ?? json['JobId'];
    if (value is! num) {
      throw const FormatException('La respuesta no contiene un jobId válido');
    }
    return EnqueuePrintJobResult(jobId: value.toInt());
  }
}

enum PrintJobStatus {
  pending,
  processing,
  done,
  failed;

  static PrintJobStatus fromApi(String value) {
    return PrintJobStatus.values.firstWhere(
      (item) => item.name == value.trim().toLowerCase(),
      orElse: () => throw FormatException(
        'Estado de impresión desconocido: $value',
      ),
    );
  }
}

class PrintJobStatusResult {
  final int jobId;
  final PrintJobStatus status;
  final String kind;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? errorMessage;

  const PrintJobStatusResult({
    required this.jobId,
    required this.status,
    required this.kind,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
  });

  factory PrintJobStatusResult.fromJson(Map<String, dynamic> json) {
    T? read<T>(String camel, String pascal) {
      final value = json[camel] ?? json[pascal];
      return value is T ? value : null;
    }

    final jobId = read<num>('jobId', 'JobId');
    final status = read<String>('status', 'Status');
    final kind = read<String>('kind', 'Kind');
    final createdAt = read<String>('createdAt', 'CreatedAt');
    if (jobId == null || status == null || kind == null || createdAt == null) {
      throw const FormatException(
        'Respuesta incompleta al consultar la impresión',
      );
    }

    DateTime? parseOptional(String camel, String pascal) {
      final value = read<String>(camel, pascal);
      return value == null ? null : DateTime.parse(value);
    }

    return PrintJobStatusResult(
      jobId: jobId.toInt(),
      status: PrintJobStatus.fromApi(status),
      kind: kind,
      createdAt: DateTime.parse(createdAt),
      startedAt: parseOptional('startedAt', 'StartedAt'),
      completedAt: parseOptional('completedAt', 'CompletedAt'),
      errorMessage: read<String>('errorMessage', 'ErrorMessage'),
    );
  }
}

class PrintJobRequestCoordinator {
  final Map<String, Future<EnqueuePrintJobResult>> _inFlight = {};

  Future<EnqueuePrintJobResult> run(
    String key,
    Future<EnqueuePrintJobResult> Function() request,
  ) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<EnqueuePrintJobResult> future;
    future = request().whenComplete(() {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = future;
    return future;
  }
}
