# Android SQLite startup hotfix — 2026-10-08

User report after updating to build 22: `Queries can be performed using SQLiteDatabase query or rawQuery methods only` for `PRAGMA busy_timeout = 1000`, plus a loading screen that did not finish.

Root cause: both SessionMutex and TrackingOutbox used execute for a PRAGMA that returns a row. Android's SQLiteDatabase rejects that route although desktop SQLite FFI accepts it. Use rawQuery in both initializers; keep the existing timeout, coordination, file names, tables and migration receipts. Do not delete or recreate customer data, clear queues, disable locking, or suppress database failures to appear successful.

Error-path correction: failure while cleaning up a failed login must still attempt the remaining credential cleanup and reach a terminal error state. SQL and database internals are not user-facing messages.

Validation: host suite plus integration_test/android_sqlite_startup_test.dart on a disposable Android API 35 emulator, using the actual sqflite and encrypted-storage plugins. This explicitly reproduces the old execute exception, verifies fixed session restore, and verifies persisted outbox points and import/ACK idempotence. No production APIs are contacted. Do not run this integration test on a driver's phone: it uses test credentials in the app's debug sandbox.

Release 1.2.6; actual Google Play versionCode is allocated by the existing publisher. No backend change, server migration, cadence or alert-policy change. Update in place through Google Play internal; do not uninstall or clear app storage.
