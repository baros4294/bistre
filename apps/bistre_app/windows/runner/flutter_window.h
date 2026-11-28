#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <mmsystem.h>
#include <sapi.h>

#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "host_media.h"
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
  bool StartMicCapture();
  void StopMicCapture();
  void DrainMicChunks();
  // Plays a WAV after the ones already queued, so streamed chunks never cut each other off.
  void QueueWav(const std::vector<uint8_t>& wav);
  void StopPlayback();
  // The system voice (SAPI) reads text; the call completes when it finishes or is stopped.
  void SpeakText(const std::wstring& text,
                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopSpeaking();
  // One dictation at a time on a worker thread; the call completes with the words heard
  // (or nothing) after a pause, 12 s, or a stop.
  void StartDictation(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopDictation();
  void FinishDictation(std::wstring* text);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> host_channel_;
  std::unique_ptr<HostMedia> media_;
  bool has_shown_ = false;
  bool pending_maximized_ = false;
  bool tray_enabled_ = false;

  // The Flutter view accepts dropped files while this is set (`RegisterFileDrop`).
  HWND file_drop_hwnd_ = nullptr;
  bool tray_icon_added_ = false;
  // The icon was added only to show a notification; it goes when the balloon closes.
  bool tray_for_balloon_only_ = false;
  // Tray menu labels from the app's catalog; Quit closes for real instead of hiding.
  std::wstring tray_open_label_ = L"Bistre";
  std::wstring tray_quit_label_;
  bool quitting_ = false;
  void ShowTrayMenu();
  struct PlayChunk {
    WAVEHDR hdr{};
    std::vector<uint8_t> pcm;
  };
  HWAVEOUT wave_out_ = nullptr;
  WAVEFORMATEX out_format_{};
  std::vector<std::unique_ptr<PlayChunk>> play_queue_;
  ISpVoice* voice_ = nullptr;  // Released in OnDestroy.
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending_speech_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending_dictation_;
  std::thread dictation_thread_;
  HANDLE dictation_cancel_ = nullptr;
  HWAVEIN wave_in_ = nullptr;
  WAVEHDR wave_hdrs_[2]{};
  std::vector<uint8_t> wave_bufs_[2];
  std::mutex mic_mutex_;
  std::vector<std::vector<uint8_t>> mic_queue_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
