#include "host_media.h"

#include <mfapi.h>
#include <mfmediaengine.h>

#include <atomic>
#include <utility>

namespace {

// Engine events arrive on a Media Foundation thread; they reach the UI thread as this.
constexpr UINT kEngineEventMessage = WM_APP + 0x51;
constexpr wchar_t kEventWindowClass[] = L"BistreMediaEvents";
constexpr wchar_t kVideoWindowClass[] = L"BistreVideoWindow";
// First size of a video window, before the file reports its own.
constexpr int kVideoWindowWidth = 960;
constexpr int kVideoWindowHeight = 540;
// A video window covers at most this share of the work area, in percent.
constexpr int kMaxWorkAreaPercent = 80;

// The engine's callback: forwards the events playback needs to the UI thread.
class EngineNotify : public IMFMediaEngineNotify {
 public:
  explicit EngineNotify(HWND target) : target_(target) {}

  STDMETHODIMP QueryInterface(REFIID riid, void** out) override {
    if (out == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMFMediaEngineNotify)) {
      *out = static_cast<IMFMediaEngineNotify*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override {
    const ULONG left = --refs_;
    if (left == 0) delete this;
    return left;
  }

  STDMETHODIMP EventNotify(DWORD event, DWORD_PTR, DWORD) override {
    if (event == MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA || event == MF_MEDIA_ENGINE_EVENT_ENDED ||
        event == MF_MEDIA_ENGINE_EVENT_ERROR) {
      PostMessageW(target_, kEngineEventMessage, event, 0);
    }
    return S_OK;
  }

 private:
  virtual ~EngineNotify() = default;
  HWND target_;
  std::atomic<ULONG> refs_{1};
};

// Releases a COM pointer when it leaves scope.
template <typename T>
struct Released {
  T* ptr = nullptr;
  ~Released() {
    if (ptr != nullptr) ptr->Release();
  }
};

void RegisterClassOnce(const wchar_t* name, WNDPROC proc, HBRUSH background) {
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  if (GetClassInfoExW(GetModuleHandleW(nullptr), name, &wc)) return;
  wc.lpfnWndProc = proc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = name;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = background;
  RegisterClassExW(&wc);
}

HostMedia* FromWindow(HWND hwnd) {
  return reinterpret_cast<HostMedia*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
}

}  // namespace

HostMedia::HostMedia(std::function<void()> on_failed) : on_failed_(std::move(on_failed)) {
  RegisterClassOnce(kEventWindowClass, &HostMedia::EventProc, nullptr);
  RegisterClassOnce(kVideoWindowClass, &HostMedia::VideoProc,
                    static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
  event_window_ = CreateWindowExW(0, kEventWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                                  nullptr, GetModuleHandleW(nullptr), nullptr);
  if (event_window_ != nullptr) {
    SetWindowLongPtrW(event_window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }
}

HostMedia::~HostMedia() {
  Stop();
  if (event_window_ != nullptr) DestroyWindow(event_window_);
  if (mf_started_) MFShutdown();
}

bool HostMedia::Play(HWND owner, const std::wstring& path, const std::wstring& title,
                     bool video) {
  Stop();
  if (event_window_ == nullptr || path.empty()) return false;
  if (!mf_started_) {
    if (FAILED(MFStartup(MF_VERSION))) return false;
    mf_started_ = true;
  }
  if (video) {
    RECT owner_rect{};
    GetWindowRect(owner, &owner_rect);
    const int x = owner_rect.left + (owner_rect.right - owner_rect.left - kVideoWindowWidth) / 2;
    const int y = owner_rect.top + (owner_rect.bottom - owner_rect.top - kVideoWindowHeight) / 2;
    video_window_ = CreateWindowExW(0, kVideoWindowClass, title.c_str(),
                                    WS_OVERLAPPEDWINDOW | WS_VISIBLE, x, y, kVideoWindowWidth,
                                    kVideoWindowHeight, owner, nullptr,
                                    GetModuleHandleW(nullptr), nullptr);
    if (video_window_ == nullptr) return false;
    SetWindowLongPtrW(video_window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }
  Released<IMFMediaEngineClassFactory> factory;
  Released<IMFAttributes> attributes;
  Released<EngineNotify> notify{new EngineNotify(event_window_)};
  HRESULT hr = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory.ptr));
  if (SUCCEEDED(hr)) hr = MFCreateAttributes(&attributes.ptr, 2);
  if (SUCCEEDED(hr)) hr = attributes.ptr->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify.ptr);
  if (SUCCEEDED(hr) && video_window_ != nullptr) {
    hr = attributes.ptr->SetUINT64(MF_MEDIA_ENGINE_PLAYBACK_HWND,
                                   reinterpret_cast<UINT64>(video_window_));
  }
  const DWORD flags = video_window_ != nullptr ? 0 : MF_MEDIA_ENGINE_AUDIOONLY;
  if (SUCCEEDED(hr)) hr = factory.ptr->CreateInstance(flags, attributes.ptr, &engine_);
  if (SUCCEEDED(hr)) {
    BSTR source = SysAllocString(path.c_str());
    hr = source != nullptr ? engine_->SetSource(source) : E_OUTOFMEMORY;
    SysFreeString(source);
  }
  if (SUCCEEDED(hr)) hr = engine_->Play();
  if (FAILED(hr)) {
    Stop();
    return false;
  }
  return true;
}

void HostMedia::Stop() {
  if (engine_ != nullptr) {
    engine_->Shutdown();
    engine_->Release();
    engine_ = nullptr;
  }
  if (video_window_ != nullptr) {
    const HWND window = video_window_;
    video_window_ = nullptr;
    DestroyWindow(window);
  }
}

void HostMedia::OnEngineEvent(DWORD event) {
  if (engine_ == nullptr) return;
  switch (event) {
    case MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA:
      FitVideoWindow();
      break;
    case MF_MEDIA_ENGINE_EVENT_ENDED:
      Stop();
      break;
    case MF_MEDIA_ENGINE_EVENT_ERROR:
      Stop();
      if (on_failed_) on_failed_();
      break;
    default:
      break;
  }
}

// Sizes the window to the video's own size, scaled down to fit the work area.
void HostMedia::FitVideoWindow() {
  if (video_window_ == nullptr || engine_ == nullptr) return;
  DWORD width = 0;
  DWORD height = 0;
  if (FAILED(engine_->GetNativeVideoSize(&width, &height)) || width == 0 || height == 0) {
    UpdateVideoRect();
    return;
  }
  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const double max_w = (work.right - work.left) * kMaxWorkAreaPercent / 100.0;
  const double max_h = (work.bottom - work.top) * kMaxWorkAreaPercent / 100.0;
  double scale = 1.0;
  if (width > max_w) scale = max_w / width;
  if (height * scale > max_h) scale = max_h / height;
  RECT frame{0, 0, static_cast<LONG>(width * scale), static_cast<LONG>(height * scale)};
  AdjustWindowRectEx(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0);
  SetWindowPos(video_window_, nullptr, 0, 0, frame.right - frame.left, frame.bottom - frame.top,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  UpdateVideoRect();
}

void HostMedia::UpdateVideoRect() {
  if (video_window_ == nullptr || engine_ == nullptr) return;
  Released<IMFMediaEngineEx> ex;
  if (FAILED(engine_->QueryInterface(IID_PPV_ARGS(&ex.ptr)))) return;
  RECT client{};
  GetClientRect(video_window_, &client);
  const MFARGB black{0, 0, 0, 255};
  ex.ptr->UpdateVideoStream(nullptr, &client, &black);
}

LRESULT CALLBACK HostMedia::EventProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kEngineEventMessage) {
    if (HostMedia* self = FromWindow(hwnd)) self->OnEngineEvent(static_cast<DWORD>(wparam));
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK HostMedia::VideoProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  HostMedia* self = FromWindow(hwnd);
  switch (message) {
    case WM_SIZE:
      if (self != nullptr) self->UpdateVideoRect();
      break;
    case WM_KEYDOWN:
      if (self != nullptr && self->engine_ != nullptr && wparam == VK_SPACE) {
        if (self->engine_->IsPaused()) {
          self->engine_->Play();
        } else {
          self->engine_->Pause();
        }
        return 0;
      }
      if (wparam == VK_ESCAPE) {
        PostMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;
    case WM_CLOSE:
      if (self != nullptr && self->video_window_ == hwnd) {
        self->Stop();
        return 0;
      }
      break;
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
