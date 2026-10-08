package com.senorarroz.delivery_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
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
    private val deviceStateReceiver = TrackingDeviceStateReceiver()

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(deviceStateReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(deviceStateReceiver, filter)
        }
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("flutter.sa_native_tracking_active", false)) return
        if (Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1) {
            deviceStateReceiver.onReceive(this, Intent(Intent.ACTION_AIRPLANE_MODE_CHANGED))
        } else {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            if (!wifi.isWifiEnabled) {
                deviceStateReceiver.onReceive(this, Intent(WifiManager.WIFI_STATE_CHANGED_ACTION))
            }
        }
    }
}

class TrackingDeviceStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("flutter.sa_native_tracking_active", false)) return
        // Capture ownership with the event. A later login must never reassign it.
        val tracking = try {
            JSONObject(prefs.getString("flutter.sa_native_tracking_context", null) ?: return)
        } catch (_: Exception) { return }
        val now = System.currentTimeMillis()
        if (now < tracking.optLong("startedAtMs", Long.MAX_VALUE) ||
            now >= tracking.optLong("autoCloseAtMs", 0L)) return

        val event = when (intent.action) {
            Intent.ACTION_AIRPLANE_MODE_CHANGED -> if (
                Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
            ) {
                "airplane_mode_enabled" to "confirmed_by_android"
            } else {
                "airplane_mode_disabled" to "confirmed_by_android"
            }
            WifiManager.WIFI_STATE_CHANGED_ACTION -> {
                val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                if (!wifi.isWifiEnabled) {
                    val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
                    val hasAlternativeConnection = capabilities?.let {
                        it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                            && !it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    } == true
                    if (hasAlternativeConnection) return
                    "wifi_disabled" to "confirmed_by_android;connectivity_unavailable=true"
                } else {
                    "wifi_enabled" to "confirmed_by_android"
                }
            }
            Intent.ACTION_BOOT_COMPLETED -> "device_restarted" to "confirmed_by_android"
            else -> return
        }

        val clientEventId = UUID.randomUUID().toString()
        val eventJson = JSONObject().apply {
            put("clientEventId", clientEventId)
            put("workSessionId", tracking.getInt("workSessionId"))
            put("_authSessionId", tracking.getString("authSessionId"))
            put("_ownerKey", tracking.getString("ownerKey"))
            put("eventType", event.first)
            put("details", event.second)
            put("recordedAt", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(Date()))
        }
        // Unique keys avoid lost updates between broadcasts and Dart imports.
        prefs.edit().putString("flutter.sa_native_device_event_${now}_$clientEventId", eventJson.toString()).apply()
    }
}
