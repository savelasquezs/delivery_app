# Android SQLite startup hotfix — 2026-10-08

User report after updating to build 22: `Queries can be performed using SQLiteDatabase query or rawQuery methods only` for `PRAGMA busy_timeout = 1000`, plus a loading screen that did not finish.

Root cause: both SessionMutex and TrackingOutbox used execute for a PRAGMA that returns a row. Android's SQLiteDatabase rejects that route although desktop SQLite FFI accepts it. Use rawQuery in both initializers; keep the existing timeout, coordination, file names, tables and migration receipts. Do not delete or recreate customer data, clear queues, disable locking, or suppress database failures to appear successful.

Error-path correction: failure while cleaning up a failed login must still attempt the remaining credential cleanup and reach a terminal error state. SQL and database internals are not user-facing messages.

Validation: host suite plus integration_test/android_sqlite_startup_test.dart on a disposable Android API 35 emulator, using the actual sqflite and encrypted-storage plugins. This explicitly reproduces the old execute exception, verifies fixed session restore, and verifies persisted outbox points and import/ACK idempotence. No production APIs are contacted. Do not run this integration test on a driver's phone: it uses test credentials in the app's debug sandbox.

## Release compatibility

Keep versionName 1.2.5 and increment only the build (local floor +23; actual versionCode allocated by the publisher). The deployed API's DeliveryAppVersionPolicy at 11e06c78 uses exact version-name equality, not a semver minimum. Publishing 1.2.6 without a coordinated backend change would trigger HTTP 426; this hotfix deliberately makes no such policy change.

No backend change, server migration, cadence or alert-policy change. Update in place through Google Play internal; do not uninstall or clear app storage. Verify the published build number rather than relying on the unchanged 1.2.5 display name.
