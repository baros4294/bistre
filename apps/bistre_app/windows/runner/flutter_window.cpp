#include "flutter_window.h"

#include <shellapi.h>
#include <shobjidl.h>
#include <windows.h>

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMsg = WM_APP + 42;
constexpr UINT kTrayIconId = 1001;
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

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return L"";
  }
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) {
    return L"";
  }
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return "";
  }
  int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                static_cast<int>(wide.size()), nullptr, 0,
                                nullptr, nullptr);
  if (len <= 0) {
    return "";
  }
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      out.data(), len, nullptr, nullptr);
  return out;
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

std::optional<std::string> ShowOpenFileDialog(HWND owner,
                                              const std::wstring& title,
                                              const std::wstring& filter_label,
                                              const std::wstring& filter_spec) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    return std::nullopt;
  }

  DWORD opts = 0;
  if (SUCCEEDED(dialog->GetOptions(&opts))) {
    dialog->SetOptions(opts | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST);
  }
  if (!title.empty()) {
    dialog->SetTitle(title.c_str());
  }
  if (!filter_label.empty() && !filter_spec.empty()) {
    COMDLG_FILTERSPEC spec[2] = {
        {filter_label.c_str(), filter_spec.c_str()},
        {L"All files", L"*.*"},
    };
    dialog->SetFileTypes(2, spec);
    dialog->SetFileTypeIndex(1);
  }

  std::optional<std::string> selected;
  if (SUCCEEDED(dialog->Show(owner))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr) {
      PWSTR psz_path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &psz_path)) &&
          psz_path != nullptr) {
        selected = WideToUtf8(psz_path);
        CoTaskMemFree(psz_path);
      }
      item->Release();
    }
  }
  dialog->Release();
  return selected;
}

std::optional<std::string> ShowSaveFileDialog(HWND owner,
                                              const std::wstring& title,
                                              const std::wstring& default_name,
                                              const std::wstring& filter_label,
                                              const std::wstring& filter_spec) {
  IFileSaveDialog* dialog = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    return std::nullopt;
  }

  DWORD opts = 0;
  if (SUCCEEDED(dialog->GetOptions(&opts))) {
    dialog->SetOptions(opts | FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST);
  }
  if (!title.empty()) {
    dialog->SetTitle(title.c_str());
  }
  if (!default_name.empty()) {
    dialog->SetFileName(default_name.c_str());
  }
  if (!filter_label.empty() && !filter_spec.empty()) {
    COMDLG_FILTERSPEC spec[2] = {
        {filter_label.c_str(), filter_spec.c_str()},
        {L"All files", L"*.*"},
    };
    dialog->SetFileTypes(2, spec);
    dialog->SetFileTypeIndex(1);
  }

  std::optional<std::string> selected;
  if (SUCCEEDED(dialog->Show(owner))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr) {
      PWSTR psz_path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &psz_path)) &&
          psz_path != nullptr) {
        selected = WideToUtf8(psz_path);
        CoTaskMemFree(psz_path);
      }
      item->Release();
    }
  }
  dialog->Release();
  return selected;
}

std::optional<std::string> ShowPickFolderDialog(HWND owner,
                                                const std::wstring& title) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    return std::nullopt;
  }

  DWORD opts = 0;
  if (SUCCEEDED(dialog->GetOptions(&opts))) {
    dialog->SetOptions(opts | FOS_PICKFOLDERS | FOS_PATHMUSTEXIST |
                       FOS_FORCEFILESYSTEM);
  }
  if (!title.empty()) {
    dialog->SetTitle(title.c_str());
  }

  std::optional<std::string> selected;
  if (SUCCEEDED(dialog->Show(owner))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item)) && item != nullptr) {
      PWSTR psz_path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &psz_path)) &&
          psz_path != nullptr) {
        std::wstring wpath(psz_path);
        const bool is_unc =
            wpath.size() > 1 && (wpath[0] == L'\\' || wpath[0] == L'/') &&
            (wpath[1] == L'\\' || wpath[1] == L'/');
        if (!is_unc && !wpath.empty()) {
          selected = WideToUtf8(wpath);
        }
        CoTaskMemFree(psz_path);
      }
      item->Release();
    }
  }
  dialog->Release();
  return selected;
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
  EnsureTrayIcon(false);
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
  if (!was_added && !tray_enabled_) {
    // Keep balloon visible without permanently pinning tray icon unless user enabled tray.
  }
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

  if (method == "setTrayEnabled" && args != nullptr) {
    tray_enabled_ = GetBoolArg(*args, "enabled", false);
    EnsureTrayIcon(tray_enabled_);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
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
    case kTrayCallbackMsg:
      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK ||
          lparam == WM_RBUTTONUP) {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        if (flutter_controller_) {
          flutter_controller_->ForceRedraw();
        }
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
