# Tracking reliability — delivery 1

## Changes

- UI and foreground tracking use `SessionRefresher`. A SQLite compare-and-swap lease serializes refresh, token writes and logout across Flutter engines. No SQL transaction spans HTTP. A 20-second cancellation deadline bounds the refresh request. Leases have heartbeats, ownership checks and expiry-based recovery after a process restart.
- Access/refresh tokens plus a stable login generation are one encrypted secure-storage record. Legacy tokens migrate under the same lock; new logins get a new generation. No token values are logged.
- Each tracking request reads current credentials. A 401 gets at most one authenticated replay. A shared, persisted pause applies to location and device-event requests; 429 respects Retry-After and transient failures use capped backoff.
- Queue passes process at most 10 entries and stop on transient/auth errors. Invalid 400/422 points go to a diagnostic quarantine; unmatched work-session/login entries are retained, not sent with another user's session.
- Known temporary work-session failures may reuse an existing, unexpired server-issued session. Generic reconciliation failures no longer delete authentication; confirmed invalidation still ends tracking.
- The foreground task reports terminal session loss to the UI.

## Boundaries

The existing JSON location/event queues and coupled capture loop remain in this delivery. Concurrent queue writes, SQLite outbox migration, capture/upload separation and detailed status are delivery 2. Old login/jornada queues are deliberately retained but not automatically reassigned. No GPS frequency or production API configuration changed.

## Validation

Run `flutter pub get`, `flutter analyze --no-fatal-infos`, and `flutter test`. Added tests exercise concurrent refresh, logout ordering, old login isolation, transient refresh cooldown, invalid rotation responses, 1,000 rejected uploads, shared Retry-After, session replacement, and independent-isolate SQLite lock arbitration.

Device acceptance still requires an Android phone: expire a token with the screen locked; test 401/429/503, airplane mode, service restart and auto-close. Verify actual accepted timestamps, not merely a running foreground notification.

`main` automatically publishes to the existing **internal** Play track. PR validation runs before merge.
