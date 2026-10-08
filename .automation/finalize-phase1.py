from pathlib import Path

def edit(name, old, new):
    p = Path(name)
    text = p.read_text()
    if old not in text:
        raise RuntimeError(f'Expected reviewed source not found: {name}')
    p.write_text(text.replace(old, new))

edit('lib/core/storage/secure_storage.dart', 'await _lease.ensureOwned();', 'await _lease!.ensureOwned();')
edit('lib/core/storage/secure_storage.dart', '''    await _storage.delete(key: _kAuthToken);
    await _storage.delete(key: _kRefreshToken);''', '''    // Legacy cleanup cannot turn a successful rotating-pair write into failure.
    try {
      await _storage.delete(key: _kAuthToken);
      await _storage.delete(key: _kRefreshToken);
    } catch (_) {}''')
edit('lib/core/auth/session_refresh.dart', '''    final attempts = min(session.refreshFailures + 1, 6);''', '''    final current = await locked.readSession();
    if (current == null || current.id != session.id ||
        current.accessToken != session.accessToken ||
        current.refreshToken != session.refreshToken) return;
    final attempts = min(session.refreshFailures + 1, 6);''')
edit('lib/core/auth/session_mutex.dart', ''''WHERE name = ? AND (owner IS NULL OR expires_at <= ? OR owner NOT LIKE ?)',
        [owner, now + leaseDuration.inMilliseconds, 'auth', now, '$pid:%'],''', ''''WHERE name = ? AND (owner IS NULL OR expires_at <= ?)',
        [owner, now + leaseDuration.inMilliseconds, 'auth', now],''')
edit('docs/tracking-reliability.md', 'process-restart recovery', 'expiry-based recovery after a process restart')
edit('lib/features/auth/presentation/auth_notifier.dart', 'discardPending: true,', 'discardPending: false,')
edit('test/delivery_app_version_test.dart', "import 'dart:convert';", "import 'dart:convert';\nimport 'package:delivery_app/core/auth/token_session.dart';")
edit('test/delivery_app_version_test.dart', '''  int clearCount = 0;

  @override
  Future<String?> getAuthToken()''', '''  int clearCount = 0;

  @override
  Future<TokenSession?> readSession() async => const TokenSession(
      id: 'version-test', accessToken: 'access-token', refreshToken: 'refresh-token');

  @override
  Future<String?> getAuthToken()''')
edit('test/session_mutex_test.dart', "import 'dart:async';\n", '')

p = Path('lib/core/api/dio_client.dart')
s = p.read_text().replace("import 'dart:async';\n\n", '')
s = s.replace('''  /// Una sola renovación a la vez (el backend rota el refresh token al usarlo).
  Completer<RefreshAccessResult>? _refreshCompleter;

''', '')
s = s.replace('''      options.extra['_sessionId'] = session?.id;''', '''      final requestSessionId = options.extra['_sessionId'];
      if (_isRetry(options) && requestSessionId != session?.id) {
        handler.reject(DioException(requestOptions: options,
          type: DioExceptionType.cancel,
          error: const ApiException('La sesión cambió. Reintenta la operación.')));
        return;
      }
      options.extra['_sessionId'] = session?.id;''')
s = s.replace('''      await _storage.clearAll();
      onSessionInvalidated?.call(reason);''', '''      final invalidated = await _storage.withSessionLock((locked) async {
        final current = await locked.readSession();
        if (current == null || current.id != err.requestOptions.extra['_sessionId']) return false;
        await locked.clearAll();
        return true;
      });
      if (!invalidated) {
        return handler.next(DioException(requestOptions: err.requestOptions,
          type: DioExceptionType.cancel,
          error: const ApiException('La sesión cambió. Reintenta la operación.')));
      }
      onSessionInvalidated?.call(reason);''')
start = s.index('  Future<RefreshAccessResult> _refreshAccessToken(')
end = s.index('  Future<void> _activateUpdateRequired(', start)
s = s[:start] + '''  Future<RefreshAccessResult> _refreshAccessToken({
    String? rejectedToken, String? expectedSessionId,
  }) async {
    if (_updatePolicy != null) return RefreshAccessUpdateRequired(_updatePolicy!);
    try {
      final contextId = expectedSessionId ?? (await _storage.readSession())?.id;
      final result = await SessionRefresher(
        storage: _storage,
        baseUrl: ApiConstants.baseUrl,
        versionHeaders: _versionInfo.headers,
      ).ensureAccess(rejectedToken: rejectedToken, expectedSessionId: contextId);
      if (result is RefreshAccessSuccess) {
        final current = await _storage.readSession();
        if (current == null || current.id != contextId) {
          return const RefreshAccessSessionChanged();
        }
        await LocationTrackingService.updateToken(current.accessToken);
        return RefreshAccessSuccess(current.accessToken);
      } else if (result is RefreshAccessSessionEnded) {
        if (await _storage.readSession() != null) return const RefreshAccessSessionChanged();
        onSessionInvalidated?.call(null);
      } else if (result is RefreshAccessUpdateRequired) {
        await _activateUpdateRequired(result.policy);
      }
      return result;
    } catch (_) {
      return const RefreshAccessTransientFailure();
    }
  }

''' + s[end:]
p.write_text(s)
