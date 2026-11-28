package dev.bistre.bistre_app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File

/**
 * The file viewer's Android actions. A file leaves the app only as a `content://` URI from
 * the app's FileProvider (`res/xml/shared_paths.xml`), which the receiving app alone may
 * read; a file outside the shared folders is refused.
 */
object ViewerFiles {
    /** Opens [path] in the app the user picks; false when it is not shared or no app opens it. */
    fun openInApp(context: Context, path: String): Boolean {
        val file = File(path)
        val uri = sharedUri(context, file) ?: return false
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeOf(file))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        // The chooser carries the read grant to the app the user picks.
        return runCatching { context.startActivity(Intent.createChooser(view, null)) }
            .onFailure { Log.w("Bistre", "file not opened: ${it.message}") }
            .isSuccess
    }

    /** Puts the picture at [path] on the clipboard; false when it is not shared. */
    fun copyPicture(context: Context, path: String): Boolean {
        val file = File(path)
        val uri = sharedUri(context, file) ?: return false
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return false
        clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, file.name, uri))
        return true
    }

    private fun sharedUri(context: Context, file: File): Uri? =
        runCatching { FileProvider.getUriForFile(context, "${context.packageName}.files", file) }
            .onFailure { Log.w("Bistre", "file not shared: ${it.message}") }
            .getOrNull()

    private fun mimeOf(file: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
}
