#ifndef RUNNER_COMPUTER_USE_H_
#define RUNNER_COMPUTER_USE_H_

#include <flutter/encodable_value.h>
#include <windows.h>

#include <string>

// `hbmp` as base64 PNG, or empty when encoding fails; the bitmap stays the caller's.
std::string EncodeHBitmapPngBase64(HBITMAP hbmp);

// Runs one computer-use action (screenshot, pointer, keyboard) from the Dart host
// channel arguments and returns its result map.
flutter::EncodableMap ExecuteWindowsComputerUse(const flutter::EncodableMap& args);

#endif  // RUNNER_COMPUTER_USE_H_
