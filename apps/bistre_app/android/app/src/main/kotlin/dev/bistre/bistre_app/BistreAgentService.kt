package dev.bistre.bistre_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager

/**
 * Run-scoped Android 15/16 `specialUse` Foreground Service for long-horizon Bistre agent runs.
 *
 * Lifecycle invariants (ADR-0012 / ADR-0013):
 * - Started strictly while `active_runs > 0` and stopped immediately when active runs drop to `0`.
 * - Holds bounded `PARTIAL_WAKE_LOCK` + `WIFI_MODE_FULL_LOW_LATENCY` strictly during active runs.
 * - Implements `onTimeout(startId, fgsType)` defensively to flush SQLite WAL and call `stopSelf()`
 *   before Android's ANR deadline.
 * - Watches `ConnectivityManager.NetworkCallback` to recover when the network switches between Wi-Fi and mobile data.
 */
class BistreAgentService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastActiveCount = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        if (action == ACTION_STOP) {
            isRunning = false
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        val activeCount = intent?.getIntExtra(EXTRA_ACTIVE_COUNT, 1) ?: 1
        val holdLocks = intent?.getBooleanExtra(EXTRA_HOLD_LOCKS, true) ?: true
        lastActiveCount = activeCount
        val summary = intent?.getStringExtra(EXTRA_SUMMARY) ?: "AI agent running in background"
        ensureNotificationChannel()
        val notification = buildNotification(activeCount, summary)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        isRunning = true
        // P15: no wake lock while every run waits for the user.
        if (holdLocks) acquireLocks() else releaseLocks()
        registerNetworkWatcher()
        // P14: never restarted by the system after the process is killed (a phantom service
        // with no run behind it); the app restarts it when a run starts.
        return START_NOT_STICKY
    }

    // P16: the app was swiped away; with nothing running the service goes too.
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (lastActiveCount <= 0) {
            isRunning = false
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        super.onTimeout(startId, fgsType)
        // Checkpoint active WAL runs and enqueue WorkManager continuation before OS ANR window.
        MainActivity.emitPowerEvent("os_timeout_imminent")
        scheduleRecoveryWorker(applicationContext)
        isRunning = false
        releaseLocks()
        stopSelf(startId)
    }

    override fun onDestroy() {
        isRunning = false
        unregisterNetworkWatcher()
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = pm?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Bistre::ActiveAgentRunWakeLock",
            )?.apply {
                setReferenceCounted(false)
                // Bounded 30-minute lease renewed on heartbeat/update so crashes never leak wake locks.
                acquire(30L * 60L * 1000L)
            }
        }
        if (wifiLock?.isHeld != true) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm?.createWifiLock(mode, "Bistre::ActiveAgentWifiLock")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        runCatching {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        }
        wakeLock = null
        runCatching {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        }
        wifiLock = null
    }

    private fun registerNetworkWatcher() {
        if (networkCallback != null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                MainActivity.emitPowerEvent("network_restored")
            }

            override fun onLost(network: Network) {
                MainActivity.emitPowerEvent("network_lost")
            }
        }
        runCatching {
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        }
    }

    private fun unregisterNetworkWatcher() {
        val cb = networkCallback ?: return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        runCatching { cm?.unregisterNetworkCallback(cb) }
        networkCallback = null
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Active AI Agent Runs",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps long-running AI agent tasks alive while screen is locked."
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(activeCount: Int, summary: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (activeCount <= 1) {
            "Bistre · Agent active"
        } else {
            "Bistre · $activeCount agents active"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(summary)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentPending)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "bistre_agent_runs"
        const val NOTIFICATION_ID = 4201
        const val ACTION_START = "dev.bistre.action.START_AGENT_FGS"
        const val ACTION_STOP = "dev.bistre.action.STOP_AGENT_FGS"
        const val EXTRA_ACTIVE_COUNT = "active_count"
        const val EXTRA_SUMMARY = "summary"
        const val EXTRA_HOLD_LOCKS = "hold_locks"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, activeCount: Int, summary: String, holdLocks: Boolean = true) {
            val intent = Intent(context, BistreAgentService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ACTIVE_COUNT, activeCount)
                putExtra(EXTRA_SUMMARY, summary)
                putExtra(EXTRA_HOLD_LOCKS, holdLocks)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, BistreAgentService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun scheduleRecoveryWorker(context: Context) {
            val req = OneTimeWorkRequestBuilder<AgentRecoveryWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                "bistre_agent_recovery",
                ExistingWorkPolicy.REPLACE,
                req,
            )
        }
    }
}
