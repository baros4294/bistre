#ifndef RUNNER_HOST_DROP_H_
#define RUNNER_HOST_DROP_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// Most files taken from one drop or one paste; the rest are ignored.
constexpr size_t kMaxDroppedFiles = 16;

// The local files on the clipboard (Explorer's Copy), at most `kMaxDroppedFiles`; folders,
// network shares, and missing files are left out.
std::vector<std::string> ClipboardFilePaths(HWND owner);

// The clipboard's picture as base64 PNG, or empty when it holds none.
std::string ClipboardImagePngBase64(HWND owner);

// Accepts files dragged onto `hwnd` and hands their UTF-8 paths to `on_drop` on the window's
// thread. Returns false when the window could not be registered; a true result is undone
// with `RevokeFileDrop`.
bool RegisterFileDrop(HWND hwnd, std::function<void(std::vector<std::string>)> on_drop);
void RevokeFileDrop(HWND hwnd);

#endif  // RUNNER_HOST_DROP_H_
