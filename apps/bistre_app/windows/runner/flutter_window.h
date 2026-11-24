#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window hosting the Flutter view plus Bistre's native Win32 desktop host channel
// (Windows 11 DWM titlebar tinting, native IFileOpenDialog / IFileSaveDialog,
// ShellExecuteW folder opening, and multi-monitor-safe window bounds persistence).
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RegisterDesktopHostChannel();
  void EmitWindowBoundsChanged();
  void EnsureTrayIcon(bool enable);
  void ShowTrayBalloon(const std::wstring& title,
                       const std::wstring& body,
                       bool play_sound);
  void HandleDesktopHostCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> host_channel_;
  bool has_shown_ = false;
  bool pending_maximized_ = false;
  bool tray_enabled_ = false;
  bool tray_icon_added_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
