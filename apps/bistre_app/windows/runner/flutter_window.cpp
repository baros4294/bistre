#include "flutter_window.h"

#include <shellapi.h>
#include <shobjidl.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  host_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
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
      if (w >= 720 && h >= 520) {
        RECT candidate = {x, y, x + w, y + h};
        if (MonitorFromRect(&candidate, MONITOR_DEFAULTTONULL) != nullptr) {
          SetWindowPos(hwnd, nullptr, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
        }
      }
      if (maximized) {
        ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
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
