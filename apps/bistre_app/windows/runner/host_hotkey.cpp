#include "host_hotkey.h"

#include <cctype>

namespace {

// The virtual key of one saved key name, or 0 when it names none.
UINT KeyOf(const std::string& name) {
  if (name.size() == 1) {
    const char c = static_cast<char>(std::toupper(static_cast<unsigned char>(name[0])));
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return static_cast<UINT>(c);
    switch (c) {
      case ',':
        return VK_OEM_COMMA;
      case '.':
        return VK_OEM_PERIOD;
      case '/':
        return VK_OEM_2;
      case ';':
        return VK_OEM_1;
      default:
        return 0;
    }
  }
  if (name.size() >= 2 && name.size() <= 3 && (name[0] == 'F' || name[0] == 'f')) {
    int n = 0;
    for (size_t i = 1; i < name.size(); ++i) {
      if (!std::isdigit(static_cast<unsigned char>(name[i]))) return 0;
      n = n * 10 + (name[i] - '0');
    }
    if (n >= 1 && n <= 12) return static_cast<UINT>(VK_F1 + n - 1);
  }
  return 0;
}

std::string Lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

}  // namespace

bool SetQuickEntryHotkey(HWND hwnd, const std::string& combo) {
  // Fails harmlessly when nothing was registered yet.
  UnregisterHotKey(hwnd, kQuickEntryHotkeyId);
  if (combo.empty()) return true;
  // A saved combo is a few short names; anything longer is not one.
  if (combo.size() > 32) return false;
  UINT mods = 0;
  UINT key = 0;
  size_t start = 0;
  while (start <= combo.size()) {
    size_t end = combo.find('+', start);
    if (end == std::string::npos) end = combo.size();
    std::string part = combo.substr(start, end - start);
    while (!part.empty() && part.front() == ' ') part.erase(part.begin());
    while (!part.empty() && part.back() == ' ') part.pop_back();
    const std::string lower = Lower(part);
    if (lower == "ctrl" || lower == "control") {
      mods |= MOD_CONTROL;
    } else if (lower == "alt") {
      mods |= MOD_ALT;
    } else if (lower == "shift") {
      mods |= MOD_SHIFT;
    } else if (lower == "meta" || lower == "win") {
      mods |= MOD_WIN;
    } else if (!part.empty()) {
      if (key != 0) return false;
      key = KeyOf(part);
      if (key == 0) return false;
    }
    start = end + 1;
  }
  // Without Ctrl, Alt or Meta the shortcut would take a key from typing in every app.
  if (key == 0 || (mods & (MOD_CONTROL | MOD_ALT | MOD_WIN)) == 0) return false;
  return RegisterHotKey(hwnd, kQuickEntryHotkeyId, mods | MOD_NOREPEAT, key) != 0;
}
