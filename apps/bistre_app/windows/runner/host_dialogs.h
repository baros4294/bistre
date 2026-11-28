#ifndef RUNNER_HOST_DIALOGS_H_
#define RUNNER_HOST_DIALOGS_H_

#include <windows.h>

#include <optional>
#include <string>

// System file dialogs owned by `owner`; each returns the chosen UTF-8 path, or nothing
// when the user cancels.
std::optional<std::string> ShowOpenFileDialog(HWND owner,
                                              const std::wstring& title,
                                              const std::wstring& filter_label,
                                              const std::wstring& filter_spec);
std::optional<std::string> ShowSaveFileDialog(HWND owner,
                                              const std::wstring& title,
                                              const std::wstring& default_name,
                                              const std::wstring& filter_label,
                                              const std::wstring& filter_spec);
std::optional<std::string> ShowPickFolderDialog(HWND owner,
                                                const std::wstring& title);

#endif  // RUNNER_HOST_DIALOGS_H_
