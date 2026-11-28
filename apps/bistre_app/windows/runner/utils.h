#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <cstdint>
#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// UTF-8 to UTF-16 and back; empty on failure.
std::wstring Utf8ToWide(const std::string& utf8);
std::string WideToUtf8(const std::wstring& wide);

// Standard Base64 (with padding) of `len` bytes at `data`.
std::string Base64EncodeBytes(const uint8_t* data, size_t len);

#endif  // RUNNER_UTILS_H_
