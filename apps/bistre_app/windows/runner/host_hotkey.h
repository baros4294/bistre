#ifndef RUNNER_HOST_HOTKEY_H_
#define RUNNER_HOST_HOTKEY_H_

#include <windows.h>

#include <string>

// The `WM_HOTKEY` id of the quick entry shortcut, which brings Bistre to the front on a
// new chat from any app.
constexpr int kQuickEntryHotkeyId = 1;

// Registers `combo` for `hwnd` as the quick entry shortcut, replacing the previous one.
// `combo` is the app's saved form: modifiers (`Ctrl`, `Alt`, `Shift`, `Meta`) and one key
// (`A`-`Z`, `0`-`9`, `F1`-`F12`, `,` `/` `.` `;`) joined by `+`, with Ctrl, Alt or Meta
// required. An empty combo only removes the old one. False when `combo` does not parse or
// another app already holds it.
bool SetQuickEntryHotkey(HWND hwnd, const std::string& combo);

#endif  // RUNNER_HOST_HOTKEY_H_
