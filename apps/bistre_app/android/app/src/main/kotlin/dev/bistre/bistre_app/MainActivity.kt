package dev.bistre.bistre_app

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.Settings
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import androidx.core.view.WindowCompat
import java.io.File
import java.util.Locale
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingVoiceResult: MethodChannel.Result? = null
    private var ttsEngine: TextToSpeech? = null
    private var ttsReady: Boolean = false
    private var mediaPlayer: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_VOICE_INPUT) {
            val cb = pendingVoiceResult
            pendingVoiceResult = null
            if (cb != null) {
                val spoken = if (resultCode == Activity.RESULT_OK) {
                    data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
                } else {
                    null
                }
                cb.success(spoken)
            }
            return
        }
        if (requestCode == REQ_PICK_FOLDER) {
            val cb = pendingFolderResult
            pendingFolderResult = null
            if (cb != null) {
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri != null) {
                    val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    runCatching { contentResolver.takePersistableUriPermission(uri, flags) }
                    cb.success(resolveTreeUriPath(uri) ?: uri.toString())
                } else {
                    cb.success(null)
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun resolveTreeUriPath(treeUri: Uri): String? {
        return runCatching {
            val docId = DocumentsContract.getTreeDocumentId(treeUri)
            val parts = docId.split(":", limit = 2)
            if (parts.size == 2 && parts[0].equals("primary", ignoreCase = true)) {
                val base = Environment.getExternalStorageDirectory().absolutePath
                if (parts[1].isEmpty()) base else "$base/${parts[1]}"
            } else {
                null
            }
        }.getOrNull()
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
                    val holdLocks = call.argument<Boolean>("holdLocks") ?: true
                    BistreAgentService.start(this, count, summary, holdLocks)
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

        val hostChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOST_CHANNEL)
        hostChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickLocalFolder" -> {
                    pendingFolderResult?.success(null)
                    pendingFolderResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                        )
                    }
                    runCatching { startActivityForResult(intent, REQ_PICK_FOLDER) }
                        .onFailure {
                            pendingFolderResult = null
                            result.success(null)
                        }
                }
                "dictateVoiceOnce" -> {
                    pendingVoiceResult?.success(null)
                    pendingVoiceResult = result
                    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                        putExtra(
                            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                        )
                        putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
                    }
                    runCatching { startActivityForResult(intent, REQ_VOICE_INPUT) }
                        .onFailure {
                            pendingVoiceResult = null
                            result.success(null)
                        }
                }
                "speakTextAloud" -> {
                    val text = call.argument<String>("text")?.trim().orEmpty()
                    if (text.isNotEmpty()) {
                        if (ttsEngine == null) {
                            ttsEngine = TextToSpeech(this) { status ->
                                ttsReady = status == TextToSpeech.SUCCESS
                                if (ttsReady) {
                                    ttsEngine?.language = Locale.getDefault()
                                    ttsEngine?.speak(text.take(3500), TextToSpeech.QUEUE_FLUSH, null, "bistre_tts")
                                }
                            }
                        } else if (ttsReady) {
                            ttsEngine?.speak(text.take(3500), TextToSpeech.QUEUE_FLUSH, null, "bistre_tts")
                        }
                    }
                    result.success(true)
                }
                "playWavBytes" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes != null && bytes.isNotEmpty()) {
                        runCatching {
                            mediaPlayer?.release()
                            val tmp = File.createTempFile("bistre_audio_", ".wav", cacheDir)
                            tmp.writeBytes(bytes)
                            mediaPlayer = MediaPlayer().apply {
                                setDataSource(tmp.absolutePath)
                                setOnCompletionListener {
                                    it.release()
                                    tmp.delete()
                                }
                                prepare()
                                start()
                            }
                        }
                    }
                    result.success(true)
                }
                "stopAudioPlayback" -> {
                    runCatching { ttsEngine?.stop() }
                    runCatching {
                        mediaPlayer?.stop()
                        mediaPlayer?.release()
                        mediaPlayer = null
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        pendingFolderResult?.success(null)
        pendingFolderResult = null
        pendingVoiceResult?.success(null)
        pendingVoiceResult = null
        runCatching { ttsEngine?.shutdown() }
        ttsEngine = null
        runCatching { mediaPlayer?.release() }
        mediaPlayer = null
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
        private const val HOST_CHANNEL = "bistre/desktop_host"
        private const val POWER_CHANNEL = "dev.bistre.app/power_guard"
        private const val TERMUX_CHANNEL = "dev.bistre.app/termux"
        private const val VAULT_CHANNEL = "dev.bistre.app/vault_key"
        private const val REQ_PICK_FOLDER = 42941
        private const val REQ_VOICE_INPUT = 42942

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
