package dev.bistre.bistre_app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File

/**
 * Files pasted or dropped into Bistre arrive as `content://` URIs the app may read only for a
 * moment, so each is copied into the app's cache (a new folder per paste or drop) and its path
 * goes to Dart, the same as a file picked on the desktop. Text items are left to Flutter.
 */
object SharedFiles {
    /** Most files one paste or drop takes. */
    private const val MAX_FILES = 16

    /** Largest file copied, in bytes (core refuses larger attachments). */
    private const val MAX_FILE_BYTES = 50L * 1024 * 1024

    /** The files on the clipboard, copied into the cache; empty for text only. */
    fun clipboardFiles(context: Context): List<String> {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val clip = clipboard?.primaryClip ?: return emptyList()
        return copyClip(context, clip)
    }

    /** Copies the URIs of [clip] into a new cache folder and returns their paths. */
    fun copyClip(context: Context, clip: ClipData?): List<String> {
        if (clip == null) return emptyList()
        val uris = (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }.take(MAX_FILES)
        if (uris.isEmpty()) return emptyList()
        val dir = File(context.cacheDir, "shared-${System.nanoTime()}")
        if (!dir.mkdirs()) return emptyList()
        return uris.mapIndexedNotNull { index, uri -> copyOne(context, uri, dir, index) }
    }

    private fun copyOne(context: Context, uri: Uri, dir: File, index: Int): String? {
        val resolver = context.contentResolver
        val name = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull()
        // Only the last path part, so a provider's name can never leave the folder.
        val safe = (name ?: "file-$index").substringAfterLast('/').ifBlank { "file-$index" }
        val dest = File(dir, safe)
        return runCatching {
            resolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_FILE_BYTES) throw IllegalStateException("file too large")
                        output.write(buf, 0, n)
                    }
                }
            } ?: return null
            dest.absolutePath
        }.onFailure {
            android.util.Log.w("Bistre", "shared file not copied: ${it.message}")
            dest.delete()
        }.getOrNull()
    }
}
