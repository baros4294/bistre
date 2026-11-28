#include "host_media.h"

#include <dlfcn.h>
#include <glib-object.h>

namespace {

// GStreamer's own values (`GstState`, `GstStateChangeReturn`), stable across 1.x.
constexpr int kGstStateNull = 1;
constexpr int kGstStatePlaying = 4;
constexpr int kGstStateChangeFailure = 0;

// The GStreamer 1.x calls Bistre makes, looked up once from `libgstreamer-1.0.so.0`.
struct Gst {
  gboolean (*init_check)(int*, char***, GError**);
  gpointer (*element_factory_make)(const gchar*, const gchar*);
  int (*element_set_state)(gpointer, int);
  gpointer (*element_get_bus)(gpointer);
  void (*bus_add_signal_watch)(gpointer);
  void (*bus_remove_signal_watch)(gpointer);
  gchar* (*filename_to_uri)(const gchar*, GError**);
  void (*object_unref)(gpointer);
};

struct Player {
  Gst gst{};
  gboolean loaded = FALSE;
  gboolean load_tried = FALSE;
  gpointer playbin = nullptr;
  gpointer bus = nullptr;
  // Set once the stream starts: an error after that (a closed video window) ends playback
  // without sending the file to another app.
  gboolean started = FALSE;
  // Counts plays, so an end queued for an earlier file never stops a later one.
  guint generation = 0;
  void (*on_failed)(gpointer) = nullptr;
  gpointer user_data = nullptr;
};

Player player;

template <typename T>
gboolean lookup(void* lib, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(lib, name));
  return *out != nullptr;
}

gboolean load_gstreamer() {
  if (player.load_tried) return player.loaded;
  player.load_tried = TRUE;
  void* lib = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == nullptr) {
    g_message("GStreamer not found; media opens in its default app");
    return FALSE;
  }
  Gst& g = player.gst;
  if (!lookup(lib, "gst_init_check", &g.init_check) ||
      !lookup(lib, "gst_element_factory_make", &g.element_factory_make) ||
      !lookup(lib, "gst_element_set_state", &g.element_set_state) ||
      !lookup(lib, "gst_element_get_bus", &g.element_get_bus) ||
      !lookup(lib, "gst_bus_add_signal_watch", &g.bus_add_signal_watch) ||
      !lookup(lib, "gst_bus_remove_signal_watch", &g.bus_remove_signal_watch) ||
      !lookup(lib, "gst_filename_to_uri", &g.filename_to_uri) ||
      !lookup(lib, "gst_object_unref", &g.object_unref)) {
    g_warning("GStreamer is missing a call Bistre needs");
    return FALSE;
  }
  g_autoptr(GError) error = nullptr;
  if (!g.init_check(nullptr, nullptr, &error)) {
    g_warning("GStreamer did not start: %s", error != nullptr ? error->message : "");
    return FALSE;
  }
  player.loaded = TRUE;
  return TRUE;
}

gboolean stop_later(gpointer generation) {
  if (GPOINTER_TO_UINT(generation) == player.generation) host_media_stop();
  return G_SOURCE_REMOVE;
}

gboolean fail_later(gpointer generation) {
  if (GPOINTER_TO_UINT(generation) != player.generation) return G_SOURCE_REMOVE;
  host_media_stop();
  if (player.on_failed != nullptr) player.on_failed(player.user_data);
  return G_SOURCE_REMOVE;
}

void on_stream_start(gpointer, gpointer, gpointer) { player.started = TRUE; }

// Bus signals run inside the bus's emission; playback ends from an idle callback after it.
void on_eos(gpointer, gpointer, gpointer) {
  g_idle_add(stop_later, GUINT_TO_POINTER(player.generation));
}

void on_error(gpointer, gpointer, gpointer) {
  g_idle_add(player.started ? stop_later : fail_later, GUINT_TO_POINTER(player.generation));
}

}  // namespace

void host_media_init(void (*on_failed)(gpointer), gpointer user_data) {
  player.on_failed = on_failed;
  player.user_data = user_data;
}

gboolean host_media_play(const gchar* path) {
  host_media_stop();
  ++player.generation;
  if (path == nullptr || *path == '\0' || !load_gstreamer()) return FALSE;
  const Gst& g = player.gst;
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* uri = g.filename_to_uri(path, &error);
  if (uri == nullptr) return FALSE;
  player.playbin = g.element_factory_make("playbin", nullptr);
  if (player.playbin == nullptr) {
    g_warning("GStreamer has no playbin (gst-plugins-base)");
    return FALSE;
  }
  g_object_set(player.playbin, "uri", uri, nullptr);
  player.bus = g.element_get_bus(player.playbin);
  if (player.bus != nullptr) {
    g.bus_add_signal_watch(player.bus);
    g_signal_connect(player.bus, "message::stream-start", G_CALLBACK(on_stream_start), nullptr);
    g_signal_connect(player.bus, "message::eos", G_CALLBACK(on_eos), nullptr);
    g_signal_connect(player.bus, "message::error", G_CALLBACK(on_error), nullptr);
  }
  if (g.element_set_state(player.playbin, kGstStatePlaying) == kGstStateChangeFailure) {
    host_media_stop();
    return FALSE;
  }
  return TRUE;
}

void host_media_stop() {
  if (!player.loaded) return;
  const Gst& g = player.gst;
  if (player.bus != nullptr) {
    g_signal_handlers_disconnect_by_func(player.bus, reinterpret_cast<gpointer>(on_stream_start),
                                         nullptr);
    g_signal_handlers_disconnect_by_func(player.bus, reinterpret_cast<gpointer>(on_eos), nullptr);
    g_signal_handlers_disconnect_by_func(player.bus, reinterpret_cast<gpointer>(on_error),
                                         nullptr);
    g.bus_remove_signal_watch(player.bus);
    g.object_unref(player.bus);
    player.bus = nullptr;
  }
  if (player.playbin != nullptr) {
    g.element_set_state(player.playbin, kGstStateNull);
    g.object_unref(player.playbin);
    player.playbin = nullptr;
  }
  player.started = FALSE;
}
