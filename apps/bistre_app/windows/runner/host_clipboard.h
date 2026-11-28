#ifndef RUNNER_HOST_CLIPBOARD_H_
#define RUNNER_HOST_CLIPBOARD_H_

#include <flutter/encodable_value.h>
#include <windows.h>

// Puts a picture from the Dart `copyPicture` call on the clipboard: straight RGBA pixels
// (`rgba`, `width`, `height`) as `CF_DIBV5` and, when given, the same picture as `PNG`
// bytes (`png`), which keeps transparency for apps that read it. False when the arguments
// are malformed or the clipboard could not be opened.
bool CopyPictureToClipboard(HWND owner, const flutter::EncodableMap& args);

#endif  // RUNNER_HOST_CLIPBOARD_H_
