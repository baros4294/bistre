#include "computer_use.h"

#include <objbase.h>
#include <wincodec.h>
#include <windows.h>

#pragma comment(lib, "windowscodecs.lib")

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include "utils.h"

namespace {

int64_t GetInt64Arg(const flutter::EncodableMap& map, const char* key, int64_t fallback = 0) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) return static_cast<int64_t>(*v32);
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) return *v64;
  if (const auto* vd = std::get_if<double>(&it->second)) return static_cast<int64_t>(*vd);
  return fallback;
}

std::string GetStrArg(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return "";
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return "";
}

}  // namespace

std::string EncodeHBitmapPngBase64(HBITMAP hbmp) {
  IWICImagingFactory* factory = nullptr;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory))) || factory == nullptr) {
    return "";
  }
  std::string out;
  IWICBitmap* wic_bmp = nullptr;
  IStream* mem_stream = nullptr;
  IWICStream* wic_stream = nullptr;
  IWICBitmapEncoder* encoder = nullptr;
  IWICBitmapFrameEncode* frame = nullptr;
  if (SUCCEEDED(factory->CreateBitmapFromHBITMAP(hbmp, nullptr, WICBitmapIgnoreAlpha, &wic_bmp)) &&
      SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &mem_stream)) &&
      SUCCEEDED(factory->CreateStream(&wic_stream)) &&
      SUCCEEDED(wic_stream->InitializeFromIStream(mem_stream)) &&
      SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) &&
      SUCCEEDED(encoder->Initialize(wic_stream, WICBitmapEncoderNoCache)) &&
      SUCCEEDED(encoder->CreateNewFrame(&frame, nullptr)) &&
      SUCCEEDED(frame->Initialize(nullptr)) &&
      SUCCEEDED(frame->WriteSource(wic_bmp, nullptr)) &&
      SUCCEEDED(frame->Commit()) &&
      SUCCEEDED(encoder->Commit())) {
    HGLOBAL hglobal = nullptr;
    if (SUCCEEDED(GetHGlobalFromStream(mem_stream, &hglobal)) && hglobal != nullptr) {
      const SIZE_T sz = GlobalSize(hglobal);
      const void* ptr = GlobalLock(hglobal);
      if (ptr != nullptr && sz > 0) {
        out = Base64EncodeBytes(static_cast<const uint8_t*>(ptr), static_cast<size_t>(sz));
      }
      if (ptr != nullptr) GlobalUnlock(hglobal);
    }
  }
  if (frame) frame->Release();
  if (encoder) encoder->Release();
  if (wic_stream) wic_stream->Release();
  if (mem_stream) mem_stream->Release();
  if (wic_bmp) wic_bmp->Release();
  factory->Release();
  return out;
}

namespace {

WORD MapVirtualKeyToken(const std::string& raw) {
  std::string k;
  k.reserve(raw.size());
  for (unsigned char c : raw) {
    k.push_back(static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c));
  }
  if (k == "ctrl" || k == "control") return VK_CONTROL;
  if (k == "shift") return VK_SHIFT;
  if (k == "alt" || k == "option") return VK_MENU;
  if (k == "win" || k == "meta" || k == "super" || k == "cmd") return VK_LWIN;
  if (k == "enter" || k == "return") return VK_RETURN;
  if (k == "esc" || k == "escape") return VK_ESCAPE;
  if (k == "tab") return VK_TAB;
  if (k == "backspace" || k == "bksp") return VK_BACK;
  if (k == "delete" || k == "del") return VK_DELETE;
  if (k == "space") return VK_SPACE;
  if (k == "up") return VK_UP;
  if (k == "down") return VK_DOWN;
  if (k == "left") return VK_LEFT;
  if (k == "right") return VK_RIGHT;
  if (k == "home") return VK_HOME;
  if (k == "end") return VK_END;
  if (k == "pageup" || k == "pgup") return VK_PRIOR;
  if (k == "pagedown" || k == "pgdn") return VK_NEXT;
  if (k.size() == 2 && k[0] == 'f' && k[1] >= '1' && k[1] <= '9') {
    return static_cast<WORD>(VK_F1 + (k[1] - '1'));
  }
  if (k == "f10") return VK_F10;
  if (k == "f11") return VK_F11;
  if (k == "f12") return VK_F12;
  if (k.size() == 1) {
    const char ch = k[0];
    if (ch >= 'a' && ch <= 'z') return static_cast<WORD>('A' + (ch - 'a'));
    if (ch >= '0' && ch <= '9') return static_cast<WORD>(ch);
  }
  return 0;
}

void SendMouseMoveAbs(int64_t x, int64_t y) {
  const int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vw = (std::max)(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
  const int vh = (std::max)(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
  INPUT inp{};
  inp.type = INPUT_MOUSE;
  inp.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  inp.mi.dx = static_cast<LONG>(((x - vx) * 65535) / vw);
  inp.mi.dy = static_cast<LONG>(((y - vy) * 65535) / vh);
  SendInput(1, &inp, sizeof(INPUT));
}

}  // namespace

flutter::EncodableMap ExecuteWindowsComputerUse(const flutter::EncodableMap& args) {
  flutter::EncodableMap out;
  const std::string action = GetStrArg(args, "action");
  if (action == "screenshot") {
    const int sw = GetSystemMetrics(SM_CXSCREEN);
    const int sh = GetSystemMetrics(SM_CYSCREEN);
    if (sw <= 0 || sh <= 0) {
      out[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
      out[flutter::EncodableValue("outputText")] =
          flutter::EncodableValue("Unable to read primary display bounds.");
      return out;
    }
    const int max_edge = 1280;
    int dw = sw;
    int dh = sh;
    if ((std::max)(sw, sh) > max_edge) {
      const double scale = static_cast<double>(max_edge) / static_cast<double>((std::max)(sw, sh));
      dw = (std::max)(1, static_cast<int>(sw * scale));
      dh = (std::max)(1, static_cast<int>(sh * scale));
    }
    HDC screen_dc = GetDC(nullptr);
    HDC mem_dc = CreateCompatibleDC(screen_dc);
    HBITMAP hbmp = CreateCompatibleBitmap(screen_dc, dw, dh);
    HGDIOBJ old = SelectObject(mem_dc, hbmp);
    SetStretchBltMode(mem_dc, HALFTONE);
    SetBrushOrgEx(mem_dc, 0, 0, nullptr);
    StretchBlt(mem_dc, 0, 0, dw, dh, screen_dc, 0, 0, sw, sh, SRCCOPY);
    SelectObject(mem_dc, old);
    const std::string b64 = EncodeHBitmapPngBase64(hbmp);
    DeleteObject(hbmp);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    if (b64.empty()) {
      out[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
      out[flutter::EncodableValue("outputText")] =
          flutter::EncodableValue("Failed to encode PNG screenshot.");
      return out;
    }
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("outputText")] =
        flutter::EncodableValue("Captured " + std::to_string(dw) + "x" + std::to_string(dh) + " screenshot.");
    out[flutter::EncodableValue("imageBase64")] = flutter::EncodableValue(b64);
    return out;
  }

  if (action == "move" || action == "click" || action == "double_click" || action == "right_click") {
    const int64_t x = GetInt64Arg(args, "x", 0);
    const int64_t y = GetInt64Arg(args, "y", 0);
    SendMouseMoveAbs(x, y);
    if (action != "move") {
      const DWORD down = (action == "right_click") ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
      const DWORD up = (action == "right_click") ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP;
      const int clicks = (action == "double_click") ? 2 : 1;
      std::vector<INPUT> seq;
      for (int i = 0; i < clicks; ++i) {
        INPUT d{}; d.type = INPUT_MOUSE; d.mi.dwFlags = down;
        INPUT u{}; u.type = INPUT_MOUSE; u.mi.dwFlags = up;
        seq.push_back(d);
        seq.push_back(u);
      }
      SendInput(static_cast<UINT>(seq.size()), seq.data(), sizeof(INPUT));
    }
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("outputText")] =
        flutter::EncodableValue("Performed " + action + " at (" + std::to_string(x) + ", " + std::to_string(y) + ").");
    return out;
  }

  if (action == "scroll") {
    const int64_t x = GetInt64Arg(args, "x", 0);
    const int64_t y = GetInt64Arg(args, "y", 0);
    const int64_t dx = GetInt64Arg(args, "delta_x", 0);
    const int64_t dy = GetInt64Arg(args, "delta_y", 0);
    SendMouseMoveAbs(x, y);
    if (dy != 0) {
      INPUT inp{};
      inp.type = INPUT_MOUSE;
      inp.mi.dwFlags = MOUSEEVENTF_WHEEL;
      inp.mi.mouseData = static_cast<DWORD>(static_cast<LONG>(-dy));
      SendInput(1, &inp, sizeof(INPUT));
    }
    if (dx != 0) {
      INPUT inp{};
      inp.type = INPUT_MOUSE;
      inp.mi.dwFlags = MOUSEEVENTF_HWHEEL;
      inp.mi.mouseData = static_cast<DWORD>(static_cast<LONG>(dx));
      SendInput(1, &inp, sizeof(INPUT));
    }
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("outputText")] = flutter::EncodableValue("Scrolled.");
    return out;
  }

  if (action == "type") {
    const std::wstring wtext = Utf8ToWide(GetStrArg(args, "text"));
    std::vector<INPUT> seq;
    seq.reserve(wtext.size() * 2);
    for (wchar_t ch : wtext) {
      INPUT down{};
      down.type = INPUT_KEYBOARD;
      down.ki.wScan = static_cast<WORD>(ch);
      down.ki.dwFlags = KEYEVENTF_UNICODE;
      INPUT up = down;
      up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      seq.push_back(down);
      seq.push_back(up);
    }
    if (!seq.empty()) {
      SendInput(static_cast<UINT>(seq.size()), seq.data(), sizeof(INPUT));
    }
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("outputText")] = flutter::EncodableValue("Typed text.");
    return out;
  }

  if (action == "key") {
    const std::string chord = GetStrArg(args, "key");
    std::vector<WORD> vks;
    size_t start = 0;
    while (start <= chord.size()) {
      size_t plus = chord.find('+', start);
      const std::string tok = (plus == std::string::npos)
                                  ? chord.substr(start)
                                  : chord.substr(start, plus - start);
      const WORD vk = MapVirtualKeyToken(tok);
      if (vk == 0) {
        out[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
        out[flutter::EncodableValue("outputText")] =
            flutter::EncodableValue("Unknown key token: " + tok);
        return out;
      }
      vks.push_back(vk);
      if (plus == std::string::npos) break;
      start = plus + 1;
    }
    std::vector<INPUT> seq;
    for (WORD vk : vks) {
      INPUT down{}; down.type = INPUT_KEYBOARD; down.ki.wVk = vk;
      seq.push_back(down);
    }
    for (auto it = vks.rbegin(); it != vks.rend(); ++it) {
      INPUT up{}; up.type = INPUT_KEYBOARD; up.ki.wVk = *it; up.ki.dwFlags = KEYEVENTF_KEYUP;
      seq.push_back(up);
    }
    if (!seq.empty()) {
      SendInput(static_cast<UINT>(seq.size()), seq.data(), sizeof(INPUT));
    }
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("outputText")] = flutter::EncodableValue("Sent key chord " + chord + ".");
    return out;
  }

  out[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
  out[flutter::EncodableValue("outputText")] =
      flutter::EncodableValue("Unsupported computerUse action: " + action);
  return out;
}
