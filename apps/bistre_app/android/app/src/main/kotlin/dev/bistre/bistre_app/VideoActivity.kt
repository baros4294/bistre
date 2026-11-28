package dev.bistre.bistre_app

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.VideoView

/**
 * Plays one video file Bistre holds, with the system's play, pause, and seek controls. It
 * ends with `RESULT_OK` when the user leaves or the video ends, and `RESULT_CANCELED` when
 * the file cannot be played, so the app can open it elsewhere.
 */
class VideoActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val path = intent.getStringExtra(EXTRA_PATH)
        if (path.isNullOrEmpty()) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        title = intent.getStringExtra(EXTRA_TITLE) ?: ""
        val video = VideoView(this)
        val frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(
                video,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER,
                ),
            )
        }
        setContentView(frame)
        val controls = MediaController(this).apply { setAnchorView(video) }
        video.setMediaController(controls)
        video.setOnPreparedListener { controls.show() }
        video.setOnCompletionListener {
            setResult(RESULT_OK)
            finish()
        }
        video.setOnErrorListener { _, _, _ ->
            setResult(RESULT_CANCELED)
            finish()
            true
        }
        setResult(RESULT_OK)
        video.setVideoPath(path)
        video.start()
    }

    companion object {
        const val EXTRA_PATH = "path"
        const val EXTRA_TITLE = "title"
    }
}
