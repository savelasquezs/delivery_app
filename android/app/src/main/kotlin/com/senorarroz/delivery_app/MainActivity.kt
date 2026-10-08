package com.senorarroz.delivery_app

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import io.flutter.app.FlutterApplication
import io.flutter.embedding.android.FlutterActivity
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

class MainActivity : FlutterActivity()

class TrackingApplication : FlutterApplication() {
    private lateinit var evidence: AndroidTrackingEvidence
    override fun onCreate() {
        super.onCreate()
        evidence = AndroidTrackingEvidence(this)
        evidence.start()
    }
}

private fun trackingPreferences(context: Context): SharedPreferences =
    context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

private fun contextSnapshot(prefs: SharedPreferences): JSONObject? = try {
    prefs.getString("flutter.sa_native_tracking_context", null)?.let { JSONObject(it) }
} catch (_: Exception) { null }

private fun activeContext(prefs: SharedPreferences): JSONObject? {
    if (!prefs.getBoolean("flutter.sa_native_tracking_active", false)) return null
    val state = contextSnapshot(prefs) ?: return null
    val now = System.currentTimeMillis()
    return state.takeIf { now >= it.optLong("startedAtMs", Long.MAX_VALUE) &&
        now < it.optLong("autoCloseAtMs", 0L) }
}

private fun isoUtc(time: Long): String =
    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date(time))

private fun queueEvidence(edit: SharedPreferences.Editor, tracking: JSONObject,
    evidence: DeviceEvidence, id: String = UUID.randomUUID().toString()) {
    val json = JSONObject().apply {
        put("clientEventId", id)
        put("workSessionId", tracking.getInt("workSessionId"))
        put("_authSessionId", tracking.getString("authSessionId"))
        put("_ownerKey", tracking.getString("ownerKey"))
        put("eventType", evidence.type)
        put("details", evidence.details)
        put("recordedAt", isoUtc(evidence.at))
        evidence.gps?.let { put("gpsEnabled", it) }
        evidence.permission?.let { put("locationPermissionGranted", it) }
        evidence.internet?.let { put("internetAvailable", it) }
    }
    // Atomic unique keys: the Dart importer removes a key only after SQL commit.
    edit.putString("flutter.sa_native_device_event_${evidence.at}_$id", json.toString())
}

/** Does not request coordinates, send HTTP, increase GPS cadence or use a second
 * foreground service. It observes OS settings during an authorized work session. */
private class AndroidTrackingEvidence(private val app: Context) {
    private val prefs = trackingPreferences(app)
    private val handler = Handler(Looper.getMainLooper())
    private var scheduled = false
    private var identity: String? = null
    private var machine = TrackingEvidenceStateMachine()
    private var lastNetwork: Boolean? = null
    private var networkEpisode: String? = null
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "flutter.sa_native_tracking_active" || key == "flutter.sa_native_tracking_context") {
            handler.post { scheduleNow() }
        }
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // Broadcast extras are not evidence. Query actual system state.
            if (intent.action == LocationManager.MODE_CHANGED_ACTION) scheduleNow()
            else TrackingDeviceStateReceiver().onReceive(context, intent)
        }
    }
    private val tick = object : Runnable {
        override fun run() {
            scheduled = false
            observe()
            if (activeContext(prefs) != null && !scheduled) {
                scheduled = true; handler.postDelayed(this, 10_000L)
            }
        }
    }

    fun start() {
        recordPreviousProcessExit()
        val filter = IntentFilter().apply {
            addAction(LocationManager.MODE_CHANGED_ACTION)
            addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
        }
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else app.registerReceiver(receiver, filter)
        prefs.registerOnSharedPreferenceChangeListener(listener)
        scheduleNow()
    }

    private fun scheduleNow() {
        handler.removeCallbacks(tick)
        scheduled = true
        handler.post(tick)
    }

    private fun observe() {
        val tracking = activeContext(prefs)
        if (tracking == null) { identity = null; machine = TrackingEvidenceStateMachine(); return }
        val key = "${tracking.getString("ownerKey")}:${tracking.getInt("workSessionId")}"
        if (identity != key) {
            identity = key; lastNetwork = null; networkEpisode = null
            val saved = try { JSONObject(prefs.getString("sa_evidence_open", "{}") ?: "{}") }
                catch (_: Exception) { JSONObject() }
            fun episode(name: String): EvidenceEpisode? {
                if (saved.optString("context") != key) return null
                val value = saved.optJSONObject(name) ?: return null
                return EvidenceEpisode(value.getString("id"), value.getLong("at"))
            }
            machine = TrackingEvidenceStateMachine(episode("gps"), episode("permission"))
            prefs.edit().putInt("sa_evidence_process_pid", Process.myPid())
                .putLong("sa_evidence_process_started", System.currentTimeMillis()).commit()
        }
        val location: Boolean? = try {
            val manager = app.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            if (Build.VERSION.SDK_INT >= 28) manager.isLocationEnabled
            else Settings.Secure.getInt(app.contentResolver, Settings.Secure.LOCATION_MODE) != Settings.Secure.LOCATION_MODE_OFF
        } catch (_: Exception) { null }
        val permission: Boolean? = try {
            fun granted(name: String) = app.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED
            granted(Manifest.permission.ACCESS_FINE_LOCATION) &&
                (Build.VERSION.SDK_INT < 29 || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
        } catch (_: Exception) { null }
        val now = System.currentTimeMillis()
        val events = machine.observe(location, permission, SystemClock.elapsedRealtime(), now).toMutableList()
        val network: Boolean? = try {
            val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val active = manager.activeNetwork
            if (active == null) false
            else manager.getNetworkCapabilities(active)?.let {
                if (it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) true else null
            }
        } catch (_: Exception) { null }
        if (network != null && network != lastNetwork) {
            if (!network) {
                networkEpisode = UUID.randomUUID().toString()
                events += DeviceEvidence("internet_lost", now,
                    "evidence_version=2;source=android_network;episode=$networkEpisode;network_available=false", internet=false)
            } else if (lastNetwork == false) {
                events += DeviceEvidence("internet_recovered", now,
                    "evidence_version=2;source=android_network;episode=$networkEpisode;network_available=true", internet=true)
                networkEpisode = null
            }
            lastNetwork = network
        }
        val snapshot = JSONObject().apply {
            put("context", key)
            fun add(name: String, value: EvidenceEpisode?) {
                value?.let { put(name, JSONObject().put("id", it.id).put("at", it.startedAt)) }
            }
            add("gps", machine.gpsEpisode); add("permission", machine.permissionEpisode)
        }.toString()
        if (events.isNotEmpty() || prefs.getString("sa_evidence_open", null) != snapshot) {
            val edit = prefs.edit().putString("sa_evidence_open", snapshot)
            for (event in events) queueEvidence(edit, tracking, event)
            if (!edit.commit()) { identity = null; return }
            if (events.any { it.type == "gps_disabled" || it.type == "location_permission_revoked" }) {
                showLocalWarning()
            }
        }
    }

    private fun showLocalWarning() {
        try {
            if (Build.VERSION.SDK_INT >= 33 && app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = "tracking_evidence"
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
                NotificationChannel(channel, "Estado de ubicación", NotificationManager.IMPORTANCE_HIGH))
            val launch = app.packageManager.getLaunchIntentForPackage(app.packageName) ?: return
            val pending = PendingIntent.getActivity(app, 5701, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(app, channel) else Notification.Builder(app)
            manager.notify(5701, builder.setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("Mantén habilitada la ubicación")
                .setContentText("Debes mantener GPS y permisos activos. Aviso pendiente de sincronizar con administración.")
                .setStyle(Notification.BigTextStyle().bigText("Debes mantener GPS y permisos activos durante la jornada. El evento quedó guardado; administración recibirá el aviso cuando se sincronice."))
                .setContentIntent(pending).setAutoCancel(true).build())
        } catch (_: Exception) { /* Evidence remains queued even when notifications are disabled. */ }
    }

    private fun recordPreviousProcessExit() {
        if (Build.VERSION.SDK_INT < 30 || !prefs.getBoolean("flutter.sa_native_tracking_active", false)) return
        val tracking = contextSnapshot(prefs) ?: return
        val pid = prefs.getInt("sa_evidence_process_pid", 0)
        val started = prefs.getLong("sa_evidence_process_started", Long.MAX_VALUE)
        if (pid <= 0 || started == Long.MAX_VALUE) return
        try {
            val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val exit = manager.getHistoricalProcessExitReasons(app.packageName, pid, 10)
                .filter { it.processName == app.packageName && it.timestamp >= started &&
                    it.timestamp >= tracking.optLong("startedAtMs", Long.MAX_VALUE) &&
                    it.timestamp < tracking.optLong("autoCloseAtMs", 0L) }
                .maxByOrNull { it.timestamp } ?: return
            val fingerprint = "$pid:${exit.timestamp}:${exit.reason}"
            if (prefs.getString("sa_evidence_last_exit", null) == fingerprint) return
            val cause = exitEvidenceCause(Build.VERSION.SDK_INT, exit.reason)
            val id = UUID.nameUUIDFromBytes("${app.packageName}:$fingerprint".toByteArray()).toString()
            val event = DeviceEvidence("app_stopped", exit.timestamp,
                "evidence_version=2;source=android_exit_info;episode=$id;exit_reason=${exit.reason};sdk=${Build.VERSION.SDK_INT};cause=$cause;detected_at=${isoUtc(System.currentTimeMillis())}")
            val edit = prefs.edit().putString("sa_evidence_last_exit", fingerprint)
                .putInt("flutter.sa_native_exit_reported_session", tracking.getInt("workSessionId"))
            queueEvidence(edit, tracking, event, id)
            edit.commit()
        } catch (_: Exception) { /* No OS record means unknown, not manual. */ }
    }
}

/** Separate manifest receiver retains reboot information. Wi-Fi/airplane state
 * are contextual facts; neither proves lack of Internet nor misconduct. */
class TrackingDeviceStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = trackingPreferences(context)
        val tracking = activeContext(prefs) ?: return
        val event = try {
            when (intent.action) {
                Intent.ACTION_AIRPLANE_MODE_CHANGED -> {
                    val enabled = Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
                    DeviceEvidence(if (enabled) "airplane_mode_enabled" else "airplane_mode_disabled",
                        System.currentTimeMillis(), "evidence_version=2;source=android_state;airplane_enabled=$enabled")
                }
                WifiManager.WIFI_STATE_CHANGED_ACTION -> {
                    val enabled = (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).isWifiEnabled
                    DeviceEvidence(if (enabled) "wifi_enabled" else "wifi_disabled", System.currentTimeMillis(),
                        "evidence_version=2;source=android_state;wifi_enabled=$enabled")
                }
                Intent.ACTION_BOOT_COMPLETED -> DeviceEvidence("device_restarted", System.currentTimeMillis(),
                    "evidence_version=2;source=android_boot;cause=technical")
                else -> return
            }
        } catch (_: Exception) { return }
        val contextKey = "${tracking.getString("ownerKey")}:${tracking.getInt("workSessionId")}:${intent.action}"
        val key = "sa_evidence_broadcast_${contextKey.hashCode()}"
        if (prefs.getString(key, null) == event.type) return
        val edit = prefs.edit().putString(key, event.type)
        queueEvidence(edit, tracking, event)
        edit.commit()
    }
}
