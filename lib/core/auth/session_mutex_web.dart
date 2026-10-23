// @dart=3.3
import 'dart:js_interop';

@JS('navigator.locks')
external _BrowserLocks get _locks;

extension type _BrowserLocks(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(JSString name, JSFunction callback);
}

Future<T> retrySqliteBusy<T>(Future<T> Function() operation,
        {Duration timeout = const Duration(seconds: 5)}) =>
    operation();

class SessionMutex {
  static final shared = SessionMutex();
  final String _name;

  SessionMutex({
    String databasePath = 'sa_session_mutex.db',
    Duration leaseDuration = const Duration(minutes: 2),
    Duration waitTimeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) : _name = databasePath == 'sa_session_mutex.db'
            ? 'senorarroz-auth'
            : 'senorarroz-$databasePath';

  Future<T> protect<T>(Future<T> Function(SessionLease lease) operation) async {
    late T result;
    await _locks
        .request(
          _name.toJS,
          ((JSAny? lock) => (() async {
                final lease = SessionLease();
                try {
                  result = await operation(lease);
                } finally {
                  lease._closed = true;
                }
                return null as JSAny?;
              })()
                  .toJS).toJS,
        )
        .toDart;
    return result;
  }
}

class SessionLease {
  bool _closed = false;

  Future<void> ensureOwned() async {
    if (_closed) throw StateError('Session lease lost');
  }
}
