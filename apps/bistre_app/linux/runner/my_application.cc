#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // `bistre/desktop_host`: the runner tells Dart about dropped files on it and answers its
  // file dialogs and picture copies.
  FlMethodChannel* host_channel;
};

// Most files one drop sends, as on Windows.
constexpr guint kMaxDroppedFiles = 16;

// Most `;`-joined patterns one dialog filter takes.
constexpr gint kMaxFilterPatterns = 16;

// Most pixels of a copied picture (Dart scales a larger one down first).
constexpr gint64 kMaxCopiedPixels = 4096LL * 4096;

static const gchar* string_arg(FlValue* args, const gchar* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : "";
}

// A modal GTK file dialog (the desktop portal's where one runs) to open or save one file:
// the chosen path, or null when cancelled. `filterSpec` has the Windows form, `*.zip;*.json`.
static FlValue* choose_file(GtkWindow* window, FlValue* args, GtkFileChooserAction action) {
  GtkFileChooserNative* chooser =
      gtk_file_chooser_native_new(string_arg(args, "title"), window, action, nullptr, nullptr);
  GtkFileChooser* files = GTK_FILE_CHOOSER(chooser);
  if (action == GTK_FILE_CHOOSER_ACTION_SAVE) {
    gtk_file_chooser_set_do_overwrite_confirmation(files, TRUE);
    gtk_file_chooser_set_current_name(files, string_arg(args, "defaultName"));
  }
  g_auto(GStrv) patterns = g_strsplit(string_arg(args, "filterSpec"), ";", kMaxFilterPatterns);
  GtkFileFilter* filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, string_arg(args, "filterLabel"));
  guint added = 0;
  for (gchar** pattern = patterns; *pattern != nullptr; ++pattern) {
    if (**pattern != '\0' && g_strcmp0(*pattern, "*.*") != 0) {
      gtk_file_filter_add_pattern(filter, *pattern);
      ++added;
    }
  }
  // The chooser takes the floating filter; with no pattern every file shows.
  if (added > 0) {
    gtk_file_chooser_add_filter(files, filter);
  } else {
    g_object_ref_sink(filter);
    g_object_unref(filter);
  }
  FlValue* chosen = nullptr;
  if (gtk_native_dialog_run(GTK_NATIVE_DIALOG(chooser)) == GTK_RESPONSE_ACCEPT) {
    g_autofree gchar* path = gtk_file_chooser_get_filename(files);
    if (path != nullptr) chosen = fl_value_new_string(path);
  }
  g_object_unref(chooser);
  return chosen != nullptr ? chosen : fl_value_new_null();
}

// Straight RGBA pixels (`rgba`, `width`, `height`) onto the clipboard as a picture.
static gboolean copy_picture(FlValue* args) {
  FlValue* rgba = fl_value_lookup_string(args, "rgba");
  FlValue* width = fl_value_lookup_string(args, "width");
  FlValue* height = fl_value_lookup_string(args, "height");
  if (rgba == nullptr || width == nullptr || height == nullptr ||
      fl_value_get_type(rgba) != FL_VALUE_TYPE_UINT8_LIST ||
      fl_value_get_type(width) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(height) != FL_VALUE_TYPE_INT) {
    return FALSE;
  }
  const gint64 w = fl_value_get_int(width);
  const gint64 h = fl_value_get_int(height);
  if (w <= 0 || h <= 0 || w * h > kMaxCopiedPixels ||
      fl_value_get_length(rgba) != static_cast<size_t>(w * h * 4)) {
    return FALSE;
  }
  g_autoptr(GBytes) bytes = g_bytes_new(fl_value_get_uint8_list(rgba), fl_value_get_length(rgba));
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_new_from_bytes(
      bytes, GDK_COLORSPACE_RGB, TRUE, 8, static_cast<int>(w), static_cast<int>(h),
      static_cast<int>(w * 4));
  gtk_clipboard_set_image(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), pixbuf);
  return TRUE;
}

// Calls from Dart on `bistre/desktop_host`; `user_data` is the app window.
static void host_method_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  const gboolean has_map = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP;
  g_autoptr(FlMethodResponse) response = nullptr;
  if (has_map && g_strcmp0(method, "saveLocalFile") == 0) {
    g_autoptr(FlValue) chosen = choose_file(window, args, GTK_FILE_CHOOSER_ACTION_SAVE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(chosen));
  } else if (has_map && g_strcmp0(method, "pickLocalFile") == 0) {
    g_autoptr(FlValue) chosen = choose_file(window, args, GTK_FILE_CHOOSER_ACTION_OPEN);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(chosen));
  } else if (has_map && g_strcmp0(method, "copyPicture") == 0) {
    g_autoptr(FlValue) copied = fl_value_new_bool(copy_picture(args));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(copied));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("bistre/desktop_host reply failed: %s", error->message);
  }
}

// Files dragged onto the window: their local paths go to Dart as `onFilesDropped`; URIs that
// are not local regular files are skipped.
static void drag_data_received_cb(GtkWidget* widget, GdkDragContext* context, gint x,
                                  gint y, GtkSelectionData* data, guint info, guint time,
                                  gpointer user_data) {
  FlMethodChannel* channel = FL_METHOD_CHANNEL(user_data);
  g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
  g_autoptr(FlValue) paths = fl_value_new_list();
  guint count = 0;
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr && count < kMaxDroppedFiles;
       ++uri) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path != nullptr && g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
      fl_value_append_take(paths, fl_value_new_string(path));
      ++count;
    }
  }
  if (count > 0) {
    fl_method_channel_invoke_method(channel, "onFilesDropped", paths, nullptr, nullptr,
                                    nullptr);
  }
  gtk_drag_finish(context, count > 0, FALSE, time);
}

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);

  // The product name, not the binary's.
  gtk_window_set_title(window, "Bistre");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);
  // Impeller by default, as on Windows; BISTRE_IMPELLER=off falls back to Skia on a GPU
  // or driver where Impeller misbehaves (for example some virtual machines).
  const gchar* impeller = g_getenv("BISTRE_IMPELLER");
  const gboolean impeller_off =
      impeller != nullptr && (g_strcmp0(impeller, "off") == 0 ||
                              g_strcmp0(impeller, "false") == 0 ||
                              g_strcmp0(impeller, "0") == 0);
  fl_dart_project_set_enable_impeller(project, !impeller_off);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // The window opens on the app's paper colour (day theme `bgCanvas`, as the Windows
  // frame does), never a black flash before the first frame; night when GTK prefers dark.
  gboolean prefer_dark = FALSE;
  GtkSettings* gtk_settings = gtk_settings_get_default();
  if (gtk_settings != nullptr) {
    g_object_get(gtk_settings, "gtk-application-prefer-dark-theme", &prefer_dark, nullptr);
  }
  gdk_rgba_parse(&background_color, prefer_dark ? "#19120D" : "#F6EFE2");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->host_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "bistre/desktop_host",
      FL_METHOD_CODEC(codec));
  gtk_drag_dest_set(GTK_WIDGET(view), GTK_DEST_DEFAULT_ALL, nullptr, 0, GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(GTK_WIDGET(view));
  g_signal_connect(view, "drag-data-received", G_CALLBACK(drag_data_received_cb),
                   self->host_channel);
  fl_method_channel_set_method_call_handler(self->host_channel, host_method_cb, window,
                                            nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->host_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
