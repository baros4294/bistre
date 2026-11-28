#ifndef RUNNER_HOST_MEDIA_H_
#define RUNNER_HOST_MEDIA_H_

#include <windows.h>

#include <functional>
#include <string>

// Plays one local sound or video file at a time with the Media Foundation Media Engine. A
// video shows in its own window owned by Bistre's (Space pauses, Esc closes); the end of the
// file, Stop, or closing that window ends playback. Lives on the UI thread; `on_failed` runs
// there when a file that started cannot be decoded.
class HostMedia {
 public:
  explicit HostMedia(std::function<void()> on_failed);
  ~HostMedia();
  HostMedia(const HostMedia&) = delete;
  HostMedia& operator=(const HostMedia&) = delete;

  // Starts `path`; false when Media Foundation cannot start it (the app then opens the file
  // in its default app).
  bool Play(HWND owner, const std::wstring& path, const std::wstring& title, bool video);
  void Stop();

 private:
  static LRESULT CALLBACK EventProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK VideoProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  void OnEngineEvent(DWORD event);
  void FitVideoWindow();
  void UpdateVideoRect();

  std::function<void()> on_failed_;
  HWND event_window_ = nullptr;
  HWND video_window_ = nullptr;
  struct IMFMediaEngine* engine_ = nullptr;
  bool mf_started_ = false;
};

#endif  // RUNNER_HOST_MEDIA_H_
