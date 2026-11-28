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
import android.util.Log
import android.view.DragEvent
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
    private var hostChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PLAY_VIDEO) {
            if (resultCode != Activity.RESULT_OK) mediaPlaybackFailed()
            return
        }
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
        this.hostChannel = hostChannel
        listenForDrops(hostChannel)
        hostChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "clipboardAttachments" -> {
                    // Copying can take a while: off the UI thread, replying on the main looper.
                    val main = Handler(Looper.getMainLooper())
                    Thread {
                        val files = SharedFiles.clipboardFiles(this)
                        main.post { result.success(mapOf("files" to files)) }
                    }.start()
                }
                "openFile" -> {
                    val path = call.argument<String>("path")
                    result.success(path != null && ViewerFiles.openInApp(this, path))
                }
                "installUpdate" -> {
                    val path = call.argument<String>("path")
                    result.success(path != null && ViewerFiles.installUpdate(this, path))
                }
                "openWebLink" -> {
                    val url = call.argument<String>("url")
                    result.success(url != null && openWebLink(url))
                }
                "copyPicture" -> {
                    val path = call.argument<String>("path")
                    result.success(path != null && ViewerFiles.copyPicture(this, path))
                }
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
                "playMediaFile" -> {
                    val path = call.argument<String>("path")
                    val started = path != null && if (call.argument<Boolean>("video") == true) {
                        playVideo(path, call.argument<String>("title") ?: "")
                    } else {
                        playSound(path)
                    }
                    result.success(started)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHONE_USE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "phoneUse") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val service = BistrePhoneUseService.instance
                if (service == null) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "outputText" to "Phone use requires enabling Bistre in Android Accessibility settings.",
                        ),
                    )
                    return@setMethodCallHandler
                }
                @Suppress("UNCHECKED_CAST")
                val args = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                service.executeAction(args) { response ->
                    Handler(Looper.getMainLooper()).post { result.success(response) }
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

    /** Plays a sound file Bistre holds; a file that cannot be decoded tells Dart. */
    private fun playSound(path: String): Boolean {
        runCatching { mediaPlayer?.release() }
        mediaPlayer = null
        return runCatching {
            mediaPlayer = MediaPlayer().apply {
                setDataSource(path)
                setOnPreparedListener { it.start() }
                setOnCompletionListener {
                    it.release()
                    if (mediaPlayer === it) mediaPlayer = null
                }
                setOnErrorListener { player, _, _ ->
                    player.release()
                    if (mediaPlayer === player) mediaPlayer = null
                    mediaPlaybackFailed()
                    true
                }
                prepareAsync()
            }
        }.onFailure { Log.w("Bistre", "sound not played: ${it.message}") }.isSuccess
    }

    /** Opens the video in Bistre's own player screen (`VideoActivity`). */
    private fun playVideo(path: String, title: String): Boolean {
        val intent = Intent(this, VideoActivity::class.java)
            .putExtra(VideoActivity.EXTRA_PATH, path)
            .putExtra(VideoActivity.EXTRA_TITLE, title)
        return runCatching { startActivityForResult(intent, REQ_PLAY_VIDEO) }
            .onFailure { Log.w("Bistre", "video not played: ${it.message}") }
            .isSuccess
    }

    private fun mediaPlaybackFailed() {
        hostChannel?.invokeMethod("onMediaPlaybackFailed", null)
    }

    /** Opens an http(s) page in the browser; any other scheme or a link with a login is refused. */
    private fun openWebLink(url: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrEmpty() || uri.userInfo != null) {
            return false
        }
        val view = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        return runCatching { startActivity(view) }
            .onFailure { Log.w("Bistre", "link not opened: ${it.message}") }
            .isSuccess
    }

    /**
     * Files dragged onto Bistre (split screen, desktop mode) are copied into the cache and sent
     * to Dart as `onFilesDropped`, as Windows does; a text-only drag is left to Flutter.
     */
    private fun listenForDrops(hostChannel: MethodChannel) {
        val main = Handler(Looper.getMainLooper())
        window.decorView.setOnDragListener { _, event ->
            when (event.action) {
                DragEvent.ACTION_DRAG_STARTED -> {
                    val desc = event.clipDescription ?: return@setOnDragListener false
                    (0 until desc.mimeTypeCount).any { desc.getMimeType(it) != "text/plain" }
                }
                DragEvent.ACTION_DROP -> {
                    val permissions = requestDragAndDropPermissions(event)
                    val clip = event.clipData
                    Thread {
                        val files = SharedFiles.copyClip(this, clip)
                        permissions?.release()
                        if (files.isNotEmpty()) {
                            main.post { hostChannel.invokeMethod("onFilesDropped", files) }
                        }
                    }.start()
                    true
                }
                else -> true
            }
        }
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
        private const val PHONE_USE_CHANNEL = "bistre/phone_use"
        private const val POWER_CHANNEL = "dev.bistre.app/power_guard"
        private const val TERMUX_CHANNEL = "dev.bistre.app/termux"
        private const val VAULT_CHANNEL = "dev.bistre.app/vault_key"
        private const val REQ_PICK_FOLDER = 42941
        private const val REQ_VOICE_INPUT = 42942
        private const val REQ_PLAY_VIDEO = 42943

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
