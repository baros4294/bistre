package dev.bistre.bistre_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * Optional Android Termux (`com.termux.RUN_COMMAND`) shell bridge.
 *
 * Requires:
 * 1. Termux installed (`com.termux`).
 * 2. User grants `com.termux.permission.RUN_COMMAND` in Android App Permissions.
 * 3. User sets `allow-external-apps = true` in `~/.termux/termux.properties`.
 */
object TermuxBridge {
    private const val TERMUX_PKG = "com.termux"
    private const val TERMUX_SERVICE = "com.termux.app.RunCommandService"
    private const val PERMISSION = "com.termux.permission.RUN_COMMAND"
    private const val ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND"

    fun statusMap(context: Context): Map<String, Any> {
        val installed = runCatching {
            context.packageManager.getPackageInfo(TERMUX_PKG, 0)
            true
        }.getOrDefault(false)
        val granted = ContextCompat.checkSelfPermission(
            context,
            PERMISSION,
        ) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "installed" to installed,
            "permissionGranted" to granted,
            "setupCommand" to "mkdir -p ~/.termux && echo \"allow-external-apps = true\" >> ~/.termux/termux.properties",
        )
    }

    fun runBackgroundCommand(
        context: Context,
        executablePath: String,
        arguments: List<String>,
        workDir: String?,
    ): Boolean {
        val status = statusMap(context)
        if (status["installed"] != true || status["permissionGranted"] != true) {
            return false
        }
        val intent = Intent().apply {
            setClassName(TERMUX_PKG, TERMUX_SERVICE)
            action = ACTION_RUN_COMMAND
            putExtra("com.termux.RUN_COMMAND_PATH", executablePath)
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arguments.toTypedArray())
            if (!workDir.isNullOrBlank()) {
                putExtra("com.termux.RUN_COMMAND_WORKDIR", workDir)
            }
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
        }
        return runCatching {
            context.startService(intent) != null
        }.getOrDefault(false)
    }
}
