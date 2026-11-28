#ifndef RUNNER_HOST_MEDIA_H_
#define RUNNER_HOST_MEDIA_H_

#include <glib.h>

// Plays one local sound or video file at a time with GStreamer's `playbin` (a video gets
// GStreamer's own window). GStreamer is loaded when first needed, so Bistre starts without
// it; then `host_media_play` returns FALSE and the app opens the file in its default app.
// `on_failed` runs on the GTK main loop when a file that started cannot be decoded.
void host_media_init(void (*on_failed)(gpointer), gpointer user_data);
gboolean host_media_play(const gchar* path);
void host_media_stop();

#endif  // RUNNER_HOST_MEDIA_H_
