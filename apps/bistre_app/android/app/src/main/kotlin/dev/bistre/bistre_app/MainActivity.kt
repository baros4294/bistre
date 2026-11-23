package dev.bistre.bistre_app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val powerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, POWER_CHANNEL)
        activePowerChannel = powerChannel

        powerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startAgentService" -> {
                    val count = call.argument<Int>("activeCount") ?: 1
                    val summary = call.argument<String>("summary") ?: "AI agent active"
                    BistreAgentService.start(this, count, summary)
                    result.success(currentPowerState())
                }
                "stopAgentService" -> {
                    BistreAgentService.stop(this)
                    result.success(currentPowerState())
                }
                "getPowerState" -> {
                    result.success(currentPowerState())
                }
                "getMemoryInfo" -> {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val info = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(info)
                    result.success(
                        mapOf(
                            "lowRamDevice" to am.isLowRamDevice,
                            "totalBytes" to info.totalMem,
                        ),
                    )
                }
                "requestIgnoreBatteryOptimizations" -> {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    runCatching { startActivity(intent) }
                    result.success(currentPowerState())
                }
                "openAppSettings" -> {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    runCatching { startActivity(intent) }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        val vaultChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VAULT_CHANNEL)
        vaultChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "obtainDataKey" -> {
                    // Keystore (especially StrongBox) calls can take hundreds of ms: keep them off
                    // the UI thread and reply on the main looper as MethodChannel requires.
                    val main = Handler(Looper.getMainLooper())
                    Thread {
                        val key = runCatching { VaultKeyStore.obtainDataKey(applicationContext) }
                        main.post {
                            key.fold(
                                onSuccess = { result.success(it) },
                                onFailure = { result.error("vault_key", it.javaClass.simpleName, null) },
                            )
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        val termuxChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TERMUX_CHANNEL)
        termuxChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> result.success(TermuxBridge.statusMap(this))
                "runCommand" -> {
                    val path = call.argument<String>("path")
                        ?: "/data/data/com.termux/files/usr/bin/bash"
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    val workDir = call.argument<String>("workDir")
                    val started = TermuxBridge.runBackgroundCommand(this, path, args, workDir)
                    result.success(started)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        activePowerChannel = null
        super.onDestroy()
    }

    private fun currentPowerState(): Map<String, Any> {
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val ignoring = pm?.isIgnoringBatteryOptimizations(packageName) == true
        return mapOf(
            "fgsActive" to BistreAgentService.isRunning,
            "batteryUnrestricted" to ignoring,
        )
    }

    companion object {
        private const val POWER_CHANNEL = "dev.bistre.app/power_guard"
        private const val TERMUX_CHANNEL = "dev.bistre.app/termux"
        private const val VAULT_CHANNEL = "dev.bistre.app/vault_key"

        @Volatile
        private var activePowerChannel: MethodChannel? = null

        fun emitPowerEvent(eventKind: String) {
            val ch = activePowerChannel ?: return
            Handler(Looper.getMainLooper()).post {
                runCatching {
                    ch.invokeMethod("onPowerEvent", mapOf("event" to eventKind))
                }
            }
        }
    }
}
