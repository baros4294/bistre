#include "flutter_window.h"

#include <shellapi.h>
#include <windows.h>

#include <algorithm>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "computer_use.h"
#include "flutter/generated_plugin_registrant.h"
#include "host_clipboard.h"
#include "host_dialogs.h"
#include "host_drop.h"
#include "host_hotkey.h"
#include "host_speech.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kTrayCallbackMsg = WM_APP + 42;
constexpr UINT kMicChunkMsg = WM_APP + 43;
constexpr UINT kSpeechEventMsg = WM_APP + 44;
constexpr UINT kDictationDoneMsg = WM_APP + 45;
constexpr UINT kTrayMenuOpen = 1;
constexpr UINT kTrayMenuQuit = 2;

constexpr UINT kTrayIconId = 1001;
constexpr size_t kMicChunkBytes = 3200;  // 100 ms @ 16 kHz, 16-bit mono PCM

constexpr const wchar_t kAutoStartRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t kAutoStartValueName[] = L"Bistre";

bool SetWindowsAutoStart(bool enable) {
  HKEY hkey = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kAutoStartRegKey, 0, KEY_SET_VALUE,
                    &hkey) != ERROR_SUCCESS) {
    return false;
  }
  bool ok = false;
  if (enable) {
    wchar_t exe_path[MAX_PATH] = {};
    DWORD len = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
      std::wstring quoted = std::wstring(L"\"") + exe_path + L"\"";
      ok = RegSetValueExW(
               hkey, kAutoStartValueName, 0, REG_SZ,
               reinterpret_cast<const BYTE*>(quoted.c_str()),
               static_cast<DWORD>((quoted.size() + 1) * sizeof(wchar_t))) ==
           ERROR_SUCCESS;
    }
  } else {
    LSTATUS st = RegDeleteValueW(hkey, kAutoStartValueName);
    ok = (st == ERROR_SUCCESS || st == ERROR_FILE_NOT_FOUND);
  }
  RegCloseKey(hkey);
  return ok;
}

COLORREF RgbIntToColorRef(int64_t rgb) {
  BYTE r = static_cast<BYTE>((rgb >> 16) & 0xFF);
  BYTE g = static_cast<BYTE>((rgb >> 8) & 0xFF);
  BYTE b = static_cast<BYTE>(rgb & 0xFF);
  return RGB(r, g, b);
}

std::string GetStringArg(const flutter::EncodableMap& args,
                         const char* key,
                         const std::string& fallback = "") {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end()) {
    if (const auto* s = std::get_if<std::string>(&it->second)) {
      return *s;
    }
  }
  return fallback;
}

int64_t GetIntArg(const flutter::EncodableMap& args,
                  const char* key,
                  int64_t fallback = 0) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end()) {
    if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
      return *v32;
    }
    if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
      return *v64;
    }
  }
  return fallback;
}

bool GetBoolArg(const flutter::EncodableMap& args,
                const char* key,
                bool fallback = false) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end()) {
    if (const auto* b = std::get_if<bool>(&it->second)) {
      return *b;
    }
  }
  return fallback;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterDesktopHostChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Files dragged onto the window reach the composer as attachments.
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  if (RegisterFileDrop(view, [this](std::vector<std::string> paths) {
        if (!host_channel_) return;
        flutter::EncodableList list;
        for (auto& path : paths) list.emplace_back(std::move(path));
        host_channel_->InvokeMethod(
            "onFilesDropped", std::make_unique<flutter::EncodableValue>(std::move(list)));
      })) {
    file_drop_hwnd_ = view;
  }

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    has_shown_ = true;
    this->ShowWithCmd(pending_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
    if (flutter_controller_) {
      // Trigger an explicit present AFTER the HWND becomes visible so Windows 11
      // DWM + ANGLE D3D11 never stalls on a hidden first-frame swapchain.
      flutter_controller_->ForceRedraw();
    }
  });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  StopMicCapture();
  StopPlayback();
  StopSpeaking();
  if (voice_ != nullptr) {
    voice_->Release();
    voice_ = nullptr;
  }
  StopDictation();
  if (dictation_thread_.joinable()) {
    dictation_thread_.join();
  }
  if (dictation_cancel_ != nullptr) {
    CloseHandle(dictation_cancel_);
    dictation_cancel_ = nullptr;
  }
  SetQuickEntryHotkey(GetHandle(), "");
  EnsureTrayIcon(false);
  if (file_drop_hwnd_ != nullptr) {
    RevokeFileDrop(file_drop_hwnd_);
    file_drop_hwnd_ = nullptr;
  }
  host_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

void FlutterWindow::EnsureTrayIcon(bool enable) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (enable) {
    tray_for_balloon_only_ = false;
  }
  if (enable && !tray_icon_added_) {
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = kTrayIconId;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = kTrayCallbackMsg;
    nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
    wcsncpy_s(nid.szTip, L"Bistre", _TRUNCATE);
    if (Shell_NotifyIconW(NIM_ADD, &nid)) {
      tray_icon_added_ = true;
    }
  } else if (!enable && tray_icon_added_) {
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = kTrayIconId;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    tray_icon_added_ = false;
  }
}

void FlutterWindow::ShowTrayBalloon(const std::wstring& title,
                                    const std::wstring& body,
                                    bool play_sound) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  const bool was_added = tray_icon_added_;
  EnsureTrayIcon(true);
  if (!tray_icon_added_) {
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = play_sound ? NIIF_INFO : (NIIF_INFO | NIIF_NOSOUND);
  wcsncpy_s(nid.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(nid.szInfo, body.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
  if (play_sound) {
    MessageBeep(MB_OK);
  }
  // With the tray off, the icon stays only while the balloon shows.
  if (!was_added && !tray_enabled_) {
    tray_for_balloon_only_ = true;
  }
}

void FlutterWindow::QueueWav(const std::vector<uint8_t>& wav) {
  // RIFF/WAVE with a PCM "fmt " chunk and a "data" chunk; anything else is ignored.
  auto u16 = [&](size_t at) { return static_cast<uint16_t>(wav[at] | (wav[at + 1] << 8)); };
  auto u32 = [&](size_t at) {
    return static_cast<uint32_t>(wav[at] | (wav[at + 1] << 8) | (wav[at + 2] << 16) |
                                 (static_cast<uint32_t>(wav[at + 3]) << 24));
  };
  if (wav.size() < 12 || memcmp(wav.data(), "RIFF", 4) != 0 ||
      memcmp(wav.data() + 8, "WAVE", 4) != 0) {
    return;
  }
  WAVEFORMATEX fmt{};
  size_t data_at = 0;
  size_t data_len = 0;
  for (size_t at = 12; at + 8 <= wav.size();) {
    const uint32_t len = u32(at + 4);
    const size_t body = at + 8;
    if (len > wav.size() - body) {
      break;
    }
    if (memcmp(wav.data() + at, "fmt ", 4) == 0 && len >= 16) {
      fmt.wFormatTag = u16(body);
      fmt.nChannels = u16(body + 2);
      fmt.nSamplesPerSec = u32(body + 4);
      fmt.nAvgBytesPerSec = u32(body + 8);
      fmt.nBlockAlign = u16(body + 12);
      fmt.wBitsPerSample = u16(body + 14);
    } else if (memcmp(wav.data() + at, "data", 4) == 0) {
      data_at = body;
      data_len = len;
    }
    at = body + len + (len & 1);
  }
  if (fmt.wFormatTag != WAVE_FORMAT_PCM || data_len == 0) {
    return;
  }
  if (wave_out_ != nullptr &&
      (fmt.nChannels != out_format_.nChannels ||
       fmt.nSamplesPerSec != out_format_.nSamplesPerSec ||
       fmt.wBitsPerSample != out_format_.wBitsPerSample)) {
    StopPlayback();
  }
  if (wave_out_ == nullptr) {
    if (waveOutOpen(&wave_out_, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) !=
        MMSYSERR_NOERROR) {
      wave_out_ = nullptr;
      return;
    }
    out_format_ = fmt;
  }
  // Free the chunks that finished playing; the queue stays bounded.
  play_queue_.erase(
      std::remove_if(play_queue_.begin(), play_queue_.end(),
                     [this](const std::unique_ptr<PlayChunk>& chunk) {
                       if ((chunk->hdr.dwFlags & WHDR_DONE) == 0) {
                         return false;
                       }
                       waveOutUnprepareHeader(wave_out_, &chunk->hdr, sizeof(WAVEHDR));
                       return true;
                     }),
      play_queue_.end());
  constexpr size_t kMaxQueuedChunks = 256;
  if (play_queue_.size() >= kMaxQueuedChunks) {
    return;
  }
  auto chunk = std::make_unique<PlayChunk>();
  chunk->pcm.assign(wav.begin() + data_at, wav.begin() + data_at + data_len);
  chunk->hdr.lpData = reinterpret_cast<LPSTR>(chunk->pcm.data());
  chunk->hdr.dwBufferLength = static_cast<DWORD>(chunk->pcm.size());
  if (waveOutPrepareHeader(wave_out_, &chunk->hdr, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
    return;
  }
  if (waveOutWrite(wave_out_, &chunk->hdr, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
    waveOutUnprepareHeader(wave_out_, &chunk->hdr, sizeof(WAVEHDR));
    return;
  }
  play_queue_.push_back(std::move(chunk));
}

void FlutterWindow::SpeakText(
    const std::wstring& text,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopSpeaking();
  if (voice_ == nullptr) {
    if (FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL,
                                IID_PPV_ARGS(&voice_)))) {
      voice_ = nullptr;
      result->Success(flutter::EncodableValue(false));
      return;
    }
    const ULONGLONG interest = SPFEI(SPEI_END_INPUT_STREAM);
    voice_->SetInterest(interest, interest);
    voice_->SetNotifyWindowMessage(GetHandle(), kSpeechEventMsg, 0, 0);
  }
  if (FAILED(voice_->Speak(text.c_str(),
                           SPF_ASYNC | SPF_PURGEBEFORESPEAK | SPF_IS_NOT_XML,
                           nullptr))) {
    result->Success(flutter::EncodableValue(false));
    return;
  }
  pending_speech_ = std::move(result);
}

void FlutterWindow::StopSpeaking() {
  if (voice_ != nullptr) {
    voice_->Speak(nullptr, SPF_PURGEBEFORESPEAK, nullptr);
  }
  if (pending_speech_) {
    pending_speech_->Success(flutter::EncodableValue(true));
    pending_speech_.reset();
  }
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kTrayMenuOpen, tray_open_label_.c_str());
  if (!tray_quit_label_.empty()) {
    AppendMenuW(menu, MF_STRING, kTrayMenuQuit, tray_quit_label_.c_str());
  }
  POINT at{};
  GetCursorPos(&at);
  // The menu closes when the user clicks elsewhere only if the window is foreground.
  SetForegroundWindow(hwnd);
  const UINT chosen = static_cast<UINT>(TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, at.x, at.y, 0, hwnd, nullptr));
  DestroyMenu(menu);
  if (chosen == kTrayMenuOpen) {
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
  } else if (chosen == kTrayMenuQuit) {
    quitting_ = true;
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
  }
}

void FlutterWindow::StartDictation(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopDictation();
  if (dictation_thread_.joinable()) {
    dictation_thread_.join();
  }
  if (dictation_cancel_ == nullptr) {
    dictation_cancel_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  }
  if (dictation_cancel_ == nullptr) {
    result->Success();
    return;
  }
  ResetEvent(dictation_cancel_);
  pending_dictation_ = std::move(result);
  HWND hwnd = GetHandle();
  HANDLE cancel = dictation_cancel_;
  dictation_thread_ = std::thread([hwnd, cancel]() {
    auto* heard = new std::wstring(DictateOnce(cancel));
    // The window owns the text once posted; a closed window frees it here.
    if (!PostMessageW(hwnd, kDictationDoneMsg, 0, reinterpret_cast<LPARAM>(heard))) {
      delete heard;
    }
  });
}

void FlutterWindow::StopDictation() {
  if (dictation_cancel_ != nullptr) {
    SetEvent(dictation_cancel_);
  }
}

void FlutterWindow::FinishDictation(std::wstring* text) {
  std::unique_ptr<std::wstring> heard(text);
  if (!pending_dictation_) {
    return;
  }
  if (heard && !heard->empty()) {
    pending_dictation_->Success(flutter::EncodableValue(WideToUtf8(*heard)));
  } else {
    pending_dictation_->Success();
  }
  pending_dictation_.reset();
}

void FlutterWindow::StopPlayback() {
  if (wave_out_ == nullptr) {
    return;
  }
  waveOutReset(wave_out_);
  for (auto& chunk : play_queue_) {
    waveOutUnprepareHeader(wave_out_, &chunk->hdr, sizeof(WAVEHDR));
  }
  play_queue_.clear();
  waveOutClose(wave_out_);
  wave_out_ = nullptr;
}

void FlutterWindow::RegisterDesktopHostChannel() {
  host_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "bistre/desktop_host",
          &flutter::StandardMethodCodec::GetInstance());
  host_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleDesktopHostCall(call, std::move(result));
      });
}

void FlutterWindow::HandleDesktopHostCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "setWindowTheme" && args != nullptr) {
    bool is_dark = GetBoolArg(*args, "isDark", false);
    COLORREF caption = RgbIntToColorRef(GetIntArg(*args, "captionRgb", 0xF6EFE2));
    COLORREF text = RgbIntToColorRef(GetIntArg(*args, "textRgb", 0x24160E));
    COLORREF border = RgbIntToColorRef(GetIntArg(*args, "borderRgb", 0xD8C8B2));
    ApplyBistreTheme(is_dark, caption, text, border);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "pickLocalFile" && args != nullptr) {
    auto chosen = ShowOpenFileDialog(
        GetHandle(), Utf8ToWide(GetStringArg(*args, "title")),
        Utf8ToWide(GetStringArg(*args, "filterLabel")),
        Utf8ToWide(GetStringArg(*args, "filterSpec")));
    if (chosen.has_value()) {
      result->Success(flutter::EncodableValue(*chosen));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "pickLocalFolder" && args != nullptr) {
    auto chosen = ShowPickFolderDialog(
        GetHandle(), Utf8ToWide(GetStringArg(*args, "title")));
    if (chosen.has_value()) {
      result->Success(flutter::EncodableValue(*chosen));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "saveLocalFile" && args != nullptr) {
    auto chosen = ShowSaveFileDialog(
        GetHandle(), Utf8ToWide(GetStringArg(*args, "title")),
        Utf8ToWide(GetStringArg(*args, "defaultName")),
        Utf8ToWide(GetStringArg(*args, "filterLabel")),
        Utf8ToWide(GetStringArg(*args, "filterSpec")));
    if (chosen.has_value()) {
      result->Success(flutter::EncodableValue(*chosen));
    } else {
      result->Success();
    }
    return;
  }

  if (method == "openFolder" && args != nullptr) {
    std::wstring path = Utf8ToWide(GetStringArg(*args, "path"));
    // Only existing local directories: never executables, shortcuts, or UNC network shares
    // (probing a share sends SMB credentials and can leak the user's NTLM hash).
    const bool is_unc = path.size() > 1 && (path[0] == L'\\' || path[0] == L'/') &&
                        (path[1] == L'\\' || path[1] == L'/');
    const DWORD attrs =
        is_unc ? INVALID_FILE_ATTRIBUTES : GetFileAttributesW(path.c_str());
    if (!path.empty() && attrs != INVALID_FILE_ATTRIBUTES &&
        (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      ShellExecuteW(GetHandle(), L"explore", path.c_str(), nullptr, nullptr,
                    SW_SHOWNORMAL);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "clipboardAttachments") {
    // Copied files win over a picture: Explorer puts both on the clipboard for an image file.
    flutter::EncodableList files;
    for (auto& path : ClipboardFilePaths(GetHandle())) files.emplace_back(std::move(path));
    flutter::EncodableMap out;
    out[flutter::EncodableValue("png")] = flutter::EncodableValue(
        files.empty() ? ClipboardImagePngBase64(GetHandle()) : std::string());
    out[flutter::EncodableValue("files")] = flutter::EncodableValue(std::move(files));
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "copyPicture" && args != nullptr) {
    result->Success(flutter::EncodableValue(CopyPictureToClipboard(GetHandle(), *args)));
    return;
  }

  if (method == "openFile" && args != nullptr) {
    std::wstring path = Utf8ToWide(GetStringArg(*args, "path"));
    // An existing local file only, never a folder or a UNC network share; Dart refuses
    // executables, scripts, and shortcuts before asking (`blockedOpenExtensions`).
    const bool is_unc = path.size() > 1 && (path[0] == L'\\' || path[0] == L'/') &&
                        (path[1] == L'\\' || path[1] == L'/');
    const DWORD attrs =
        is_unc ? INVALID_FILE_ATTRIBUTES : GetFileAttributesW(path.c_str());
    const bool opened =
        !path.empty() && attrs != INVALID_FILE_ATTRIBUTES &&
        (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
        reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", path.c_str(), nullptr,
                                                nullptr, SW_SHOWNORMAL)) > 32;
    result->Success(flutter::EncodableValue(opened));
    return;
  }

  if (method == "openWebLink" && args != nullptr) {
    std::wstring url = Utf8ToWide(GetStringArg(*args, "url"));
    // Only http(s): any other scheme would run a local file or another app's protocol handler.
    // Dart sends the normalized URL (lowercase scheme, no spaces or quotes).
    const bool web = url.rfind(L"https://", 0) == 0 || url.rfind(L"http://", 0) == 0;
    const bool opened =
        web && url.find_first_of(L" \t\r\n\"") == std::wstring::npos &&
        reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", url.c_str(), nullptr,
                                                nullptr, SW_SHOWNORMAL)) > 32;
    result->Success(flutter::EncodableValue(opened));
    return;
  }

  if (method == "setWindowTitle" && args != nullptr) {
    std::wstring title = Utf8ToWide(GetStringArg(*args, "title"));
    if (GetHandle() && !title.empty()) {
      SetWindowTextW(GetHandle(), title.c_str());
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "getTotalMemoryBytes") {
    MEMORYSTATUSEX status{};
    status.dwLength = sizeof(status);
    const int64_t total =
        GlobalMemoryStatusEx(&status) ? static_cast<int64_t>(status.ullTotalPhys) : 0;
    result->Success(flutter::EncodableValue(total));
    return;
  }

  if (method == "getWindowBounds") {
    WINDOWPLACEMENT wp{};
    wp.length = sizeof(WINDOWPLACEMENT);
    if (GetHandle() && GetWindowPlacement(GetHandle(), &wp)) {
      const RECT& r = wp.rcNormalPosition;
      flutter::EncodableMap map;
      map[flutter::EncodableValue("x")] = flutter::EncodableValue(static_cast<int32_t>(r.left));
      map[flutter::EncodableValue("y")] = flutter::EncodableValue(static_cast<int32_t>(r.top));
      map[flutter::EncodableValue("width")] =
          flutter::EncodableValue(static_cast<int32_t>(r.right - r.left));
      map[flutter::EncodableValue("height")] =
          flutter::EncodableValue(static_cast<int32_t>(r.bottom - r.top));
      map[flutter::EncodableValue("maximized")] =
          flutter::EncodableValue(wp.showCmd == SW_SHOWMAXIMIZED);
      result->Success(flutter::EncodableValue(map));
      return;
    }
    result->Success();
    return;
  }

  if (method == "setWindowBounds" && args != nullptr) {
    HWND hwnd = GetHandle();
    if (hwnd != nullptr) {
      int x = static_cast<int>(GetIntArg(*args, "x", 48));
      int y = static_cast<int>(GetIntArg(*args, "y", 40));
      int w = static_cast<int>(GetIntArg(*args, "width", 1320));
      int h = static_cast<int>(GetIntArg(*args, "height", 820));
      bool maximized = GetBoolArg(*args, "maximized", false);
      pending_maximized_ = maximized;

      WINDOWPLACEMENT cur{};
      cur.length = sizeof(WINDOWPLACEMENT);
      const bool have_cur = GetWindowPlacement(hwnd, &cur) != FALSE;
      const bool cur_max = have_cur && cur.showCmd == SW_SHOWMAXIMIZED;
      const bool same_rect =
          have_cur && cur.rcNormalPosition.left == x &&
          cur.rcNormalPosition.top == y &&
          (cur.rcNormalPosition.right - cur.rcNormalPosition.left) == w &&
          (cur.rcNormalPosition.bottom - cur.rcNormalPosition.top) == h;

      bool changed = false;
      if (!same_rect && w >= 720 && h >= 520) {
        RECT candidate = {x, y, x + w, y + h};
        if (MonitorFromRect(&candidate, MONITOR_DEFAULTTONULL) != nullptr) {
          SetWindowPos(hwnd, nullptr, x, y, w, h,
                       SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
          changed = true;
        }
      }
      if (has_shown_ && (changed || cur_max != maximized)) {
        ShowWindow(hwnd, maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
        UpdateWindow(hwnd);
        if (flutter_controller_) {
          flutter_controller_->ForceRedraw();
        }
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "isWindowFocused") {
    HWND hwnd = GetHandle();
    const bool focused = hwnd != nullptr && GetForegroundWindow() == hwnd;
    result->Success(flutter::EncodableValue(focused));
    return;
  }

  if (method == "showNotification" && args != nullptr) {
    ShowTrayBalloon(Utf8ToWide(GetStringArg(*args, "title", "Bistre")),
                    Utf8ToWide(GetStringArg(*args, "body")),
                    GetBoolArg(*args, "playSound", false));
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setAutoStart" && args != nullptr) {
    const bool enabled = GetBoolArg(*args, "enabled", false);
    result->Success(flutter::EncodableValue(SetWindowsAutoStart(enabled)));
    return;
  }

  if (method == "setQuickEntryHotkey" && args != nullptr) {
    result->Success(flutter::EncodableValue(
        SetQuickEntryHotkey(GetHandle(), GetStringArg(*args, "combo"))));
    return;
  }
  if (method == "setTrayEnabled" && args != nullptr) {
    tray_enabled_ = GetBoolArg(*args, "enabled", false);
    EnsureTrayIcon(tray_enabled_);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "playNotificationSound") {
    MessageBeep(MB_OK);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "playWavBytes" && args != nullptr) {
    auto it = args->find(flutter::EncodableValue("bytes"));
    if (it != args->end()) {
      if (const auto* bytes = std::get_if<std::vector<uint8_t>>(&it->second)) {
        QueueWav(*bytes);
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setTrayLabels" && args != nullptr) {
    tray_open_label_ = Utf8ToWide(GetStringArg(*args, "open"));
    tray_quit_label_ = Utf8ToWide(GetStringArg(*args, "quit"));
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "dictateVoiceOnce") {
    StartDictation(std::move(result));
    return;
  }

  if (method == "stopVoiceDictation") {
    StopDictation();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "speakTextAloud" && args != nullptr) {
    SpeakText(Utf8ToWide(GetStringArg(*args, "text")), std::move(result));
    return;
  }

  if (method == "stopAudioPlayback") {
    StopPlayback();
    StopSpeaking();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "startMicCapture") {
    result->Success(flutter::EncodableValue(StartMicCapture()));
    return;
  }

  if (method == "computerUse" && args != nullptr) {
    result->Success(flutter::EncodableValue(ExecuteWindowsComputerUse(*args)));
    return;
  }

  if (method == "stopMicCapture") {
    StopMicCapture();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

bool FlutterWindow::StartMicCapture() {
  StopMicCapture();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  WAVEFORMATEX fmt{};
  fmt.wFormatTag = WAVE_FORMAT_PCM;
  fmt.nChannels = 1;
  fmt.nSamplesPerSec = 16000;
  fmt.wBitsPerSample = 16;
  fmt.nBlockAlign = 2;
  fmt.nAvgBytesPerSec = 32000;
  if (waveInOpen(&wave_in_, WAVE_MAPPER, &fmt,
                 reinterpret_cast<DWORD_PTR>(hwnd), 0,
                 CALLBACK_WINDOW) != MMSYSERR_NOERROR) {
    wave_in_ = nullptr;
    return false;
  }
  for (int i = 0; i < 2; ++i) {
    wave_bufs_[i].assign(kMicChunkBytes, 0);
    wave_hdrs_[i] = WAVEHDR{};
    wave_hdrs_[i].lpData = reinterpret_cast<LPSTR>(wave_bufs_[i].data());
    wave_hdrs_[i].dwBufferLength = static_cast<DWORD>(kMicChunkBytes);
    waveInPrepareHeader(wave_in_, &wave_hdrs_[i], sizeof(WAVEHDR));
    waveInAddBuffer(wave_in_, &wave_hdrs_[i], sizeof(WAVEHDR));
  }
  waveInStart(wave_in_);
  return true;
}

void FlutterWindow::StopMicCapture() {
  if (wave_in_ != nullptr) {
    waveInStop(wave_in_);
    waveInReset(wave_in_);
    for (int i = 0; i < 2; ++i) {
      waveInUnprepareHeader(wave_in_, &wave_hdrs_[i], sizeof(WAVEHDR));
      wave_bufs_[i].clear();
    }
    waveInClose(wave_in_);
    wave_in_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(mic_mutex_);
  mic_queue_.clear();
}

void FlutterWindow::DrainMicChunks() {
  if (!host_channel_) {
    return;
  }
  std::vector<std::vector<uint8_t>> batch;
  {
    std::lock_guard<std::mutex> lock(mic_mutex_);
    batch.swap(mic_queue_);
  }
  for (const auto& pcm : batch) {
    if (pcm.empty()) continue;
    host_channel_->InvokeMethod(
        "onMicPcmChunk",
        std::make_unique<flutter::EncodableValue>(
            Base64EncodeBytes(pcm.data(), pcm.size())));
  }
}

void FlutterWindow::EmitWindowBoundsChanged() {
  if (!host_channel_ || !has_shown_) {
    return;
  }
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(hwnd, &wp)) {
    return;
  }
  const RECT& r = wp.rcNormalPosition;
  flutter::EncodableMap map;
  map[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<int32_t>(r.left));
  map[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<int32_t>(r.top));
  map[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int32_t>(r.right - r.left));
  map[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int32_t>(r.bottom - r.top));
  map[flutter::EncodableValue("maximized")] =
      flutter::EncodableValue(wp.showCmd == SW_SHOWMAXIMIZED);
  host_channel_->InvokeMethod(
      "onWindowBoundsChanged",
      std::make_unique<flutter::EncodableValue>(map));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // With the tray on, closing the window keeps Bistre running in the tray (before the
  // engine turns the close into an app exit); Quit in the tray menu closes it.
  if (message == WM_CLOSE && tray_enabled_ && tray_icon_added_ && !quitting_) {
    EmitWindowBoundsChanged();
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_EXITSIZEMOVE:
      EmitWindowBoundsChanged();
      break;
    case WM_SIZE:
      if (wparam == SIZE_MAXIMIZED || wparam == SIZE_RESTORED) {
        EmitWindowBoundsChanged();
      }
      break;
    case WM_CLOSE:
      EmitWindowBoundsChanged();
      break;
    case MM_WIM_DATA: {
      auto* hdr = reinterpret_cast<WAVEHDR*>(lparam);
      if (wave_in_ != nullptr && hdr != nullptr && hdr->dwBytesRecorded > 0) {
        const auto* ptr = reinterpret_cast<const uint8_t*>(hdr->lpData);
        std::vector<uint8_t> chunk(ptr, ptr + hdr->dwBytesRecorded);
        {
          std::lock_guard<std::mutex> lock(mic_mutex_);
          if (mic_queue_.size() < 16) {
            mic_queue_.push_back(std::move(chunk));
          }
        }
        PostMessageW(hwnd, kMicChunkMsg, 0, 0);
        waveInAddBuffer(wave_in_, hdr, sizeof(WAVEHDR));
      }
      return 0;
    }
    case kMicChunkMsg:
      DrainMicChunks();
      return 0;
    case kDictationDoneMsg:
      FinishDictation(reinterpret_cast<std::wstring*>(lparam));
      return 0;
    case kSpeechEventMsg:
      if (voice_ != nullptr) {
        SPEVENT event{};
        ULONG fetched = 0;
        // Only end-of-stream events are asked for; their parameters own no memory.
        while (SUCCEEDED(voice_->GetEvents(1, &event, &fetched)) && fetched == 1) {
          if (event.eEventId == SPEI_END_INPUT_STREAM && pending_speech_) {
            pending_speech_->Success(flutter::EncodableValue(true));
            pending_speech_.reset();
          }
        }
      }
      return 0;
    case kTrayCallbackMsg:
      if ((lparam == NIN_BALLOONTIMEOUT || lparam == NIN_BALLOONHIDE ||
           lparam == NIN_BALLOONUSERCLICK) &&
          tray_for_balloon_only_ && !tray_enabled_) {
        EnsureTrayIcon(false);
        tray_for_balloon_only_ = false;
      }
      if (lparam == WM_RBUTTONUP && tray_enabled_) {
        ShowTrayMenu();
        return 0;
      }
      if (lparam == NIN_BALLOONUSERCLICK || lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK ||
          lparam == WM_RBUTTONUP) {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        if (flutter_controller_) {
          flutter_controller_->ForceRedraw();
        }
        return 0;
      }
      break;
    case WM_HOTKEY:
      if (wparam == kQuickEntryHotkeyId) {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        if (host_channel_) host_channel_->InvokeMethod("onQuickEntry", nullptr);
        return 0;
      }
      break;
    case WM_SETTINGCHANGE:
      if (lparam != 0 &&
          wcscmp(reinterpret_cast<const wchar_t*>(lparam),
                 L"ImmersiveColorSet") == 0 &&
          host_channel_) {
        host_channel_->InvokeMethod("onSystemThemeChanged", nullptr);
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
