#include "host_dialogs.h"

#include <shobjidl.h>

#include "utils.h"

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
