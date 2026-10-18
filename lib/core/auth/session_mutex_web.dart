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

  Future<T> protect<T>(Future<T> Function(SessionLease lease) operation) async {
    late T result;
    await _locks.request('senorarroz-auth'.toJS,
      ((JSAny? lock) => (() async {
        final lease = SessionLease();
        try {
          result = await operation(lease);
        } finally {
          lease._closed = true;
        }
        return null as JSAny?;
      })().toJS).toJS,
    ).toDart;
    return result;
  }
}

class SessionLease {
  bool _closed = false;

  Future<void> ensureOwned() async {
    if (_closed) throw StateError('Session lease lost');
  }
}
