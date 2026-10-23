# Tracking reliability — delivery 1

## Android SQLite contention — 2026-10-23

Build 33 on the connected POCO X7 Pro repeatedly reported `SqfliteDatabaseException`
and ten-second database-lock warnings while the session screen kept loading.
Production login requests completed in 331–409 ms; work-session requests completed
in under 220 ms in the inspected incident window.

The UI and GPS engine open independent native connections to the outbox. Their
multi-call transactions could compete for SQLite's writer while sqflite's single
Android worker was also needed to finish the owning transaction. Retrying after
SQLite reports busy does not prevent this contention.

Outbox schema initialization and every explicit transaction now acquire a separate
SQLite CAS lease before starting a transaction. Authentication keeps its own lock;
no HTTP request runs under the outbox lease. The ten-second lease recovers after a
process exits, renews while active, and is checked before commit. Existing database
files, pending coordinates, import receipts and ACK ownership remain intact.

Session restore has a 30-second UI deadline and offers retry with saved credentials.
Late results cannot replace a newer restore attempt. Push-token registration no
longer delays successful login. Startup logs include phase names and durations,
without credentials or location data.

`integration_test/android_sqlite_concurrency_test.dart` exercises independent real
Android connections with concurrent capture, UI reads and auth coordination, then
checks all 30 points and their ACKs. In an isolated diagnostic app on the same
phone, the previous implementation failed with `SQLITE_BUSY` at `BEGIN IMMEDIATE`;
the coordinated implementation passed. The production application was not replaced
or cleared. Publishing an in-place Google Play update and verifying the full
production login/GPS flow remain release steps.

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

# Delivery 2 — durable capture and observable synchronization

- GPS capture and upload have separate guards. Capture persists a UUID-tagged point before doing any network work. The foreground service retains the server-configured GPS interval and runs a separate 15-second synchronization tick. GPS/permission failures do not prevent uploading already captured authorized history.
- Locations and device events use an SQLite outbox. ACK removes only the acknowledged ID in a short transaction; captures cannot be overwritten by a rewritten JSON queue. Retry keeps the original UUID and timestamp. The server's existing duplicate-ID protection covers a crash after remote acceptance but before local ACK.
- Ownership is recorded as API + deliveryman + branch + installation, using the server-issued work-session DTO. A later login of the same owner can recover owned history; another owner cannot. Authentication generations still guard in-flight responses. Unverifiable legacy records are preserved in diagnostic quarantine, never attributed to a different driver.
- Legacy import and an import receipt commit together. Preference removal follows that commit. Re-running import after a crash or an ACK is idempotent. Android events now record their original work-session and owner metadata and stop at the known workday cutoff.
- Each pass is bounded (up to ten locations, three events, a 20-second loop budget and per-request deadline). The most recent current-session point is sent first; historical points then backfill in capture order. Deploy the paired API freshness guard before this version so replayed history cannot trigger live geofences/route completion. Only a recent current-session response may adjust the live tracking mode. The admin's existing recordedAt guard ignores older marker updates. The paired server guard preserves historical records and notifications but limits live route effects to the newest non-stale position.
- The home banner reads confirmed timestamps, heartbeat, pending count and GPS/upload issues from local SQLite, not an HTTP poll. It does not display a healthy state merely because the notification is running. Successful point timestamps never move backwards when historical ACKs arrive.
- Logout/update/automatic cutoff stop capture without deleting pending rows. SQLite and encrypted auth data remain in the application sandbox. Uninstall/clear-data still removes local history; do not recommend either as a troubleshooting step before pending records are recovered.

## Additional regression tests

Outbox tests cover concurrent capture vs ACK, freshness reservations, old ACK ordering, cross-owner isolation, reconnect after login, stale context commands, idempotent migration, malformed/unbound records, rejection quarantine and database reopen. Scheduler tests prove upload latency and GPS exceptions do not block each other. Physical Android verification (background permissions, OEM battery restrictions, reboot, Play update, cutoff and realistic workday) remains required before declaring the incident resolved for every phone.
