#include "host_drop.h"

#include <ole2.h>
#include <shellapi.h>

#include <utility>

#include "computer_use.h"
#include "utils.h"

namespace {

// Longest path DragQueryFileW can return, in UTF-16 units (the extended-length limit).
constexpr UINT kMaxPathUnits = 32767;

bool IsPlainLocalFile(const std::wstring& path) {
  const bool is_unc = path.size() > 1 && (path[0] == L'\\' || path[0] == L'/') &&
                      (path[1] == L'\\' || path[1] == L'/');
  if (path.empty() || is_unc) return false;
  const DWORD attrs = GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::vector<std::string> PathsFromHDrop(HDROP drop) {
  std::vector<std::string> paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count && paths.size() < kMaxDroppedFiles; ++i) {
    const UINT len = DragQueryFileW(drop, i, nullptr, 0);
    if (len == 0 || len > kMaxPathUnits) continue;
    std::wstring path(len + 1, L'\0');
    if (DragQueryFileW(drop, i, path.data(), len + 1) != len) continue;
    path.resize(len);
    if (IsPlainLocalFile(path)) paths.push_back(WideToUtf8(path));
  }
  return paths;
}

class FileDropTarget : public IDropTarget {
 public:
  explicit FileDropTarget(std::function<void(std::vector<std::string>)> on_drop)
      : on_drop_(std::move(on_drop)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
    if (out == nullptr) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *out = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&refs_));
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const LONG left = InterlockedDecrement(&refs_);
    if (left == 0) delete this;
    return static_cast<ULONG>(left);
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    accepts_ = data != nullptr && data->QueryGetData(&fmt) == S_OK;
    *effect = accepts_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = accepts_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    accepts_ = false;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    accepts_ = false;
    FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium{};
    if (data == nullptr || FAILED(data->GetData(&fmt, &medium))) return S_OK;
    std::vector<std::string> paths = PathsFromHDrop(static_cast<HDROP>(medium.hGlobal));
    ReleaseStgMedium(&medium);
    if (!paths.empty()) {
      *effect = DROPEFFECT_COPY;
      on_drop_(std::move(paths));
    }
    return S_OK;
  }

 private:
  virtual ~FileDropTarget() = default;

  LONG refs_ = 1;
  bool accepts_ = false;
  std::function<void(std::vector<std::string>)> on_drop_;
};

}  // namespace

std::vector<std::string> ClipboardFilePaths(HWND owner) {
  std::vector<std::string> paths;
  if (!IsClipboardFormatAvailable(CF_HDROP) || !OpenClipboard(owner)) return paths;
  HANDLE drop = GetClipboardData(CF_HDROP);
  if (drop != nullptr) paths = PathsFromHDrop(static_cast<HDROP>(drop));
  CloseClipboard();
  return paths;
}

std::string ClipboardImagePngBase64(HWND owner) {
  if (!IsClipboardFormatAvailable(CF_BITMAP) || !OpenClipboard(owner)) return "";
  std::string png;
  // The clipboard owns this bitmap; it is read, never freed here.
  HANDLE bitmap = GetClipboardData(CF_BITMAP);
  if (bitmap != nullptr) png = EncodeHBitmapPngBase64(static_cast<HBITMAP>(bitmap));
  CloseClipboard();
  return png;
}

bool RegisterFileDrop(HWND hwnd, std::function<void(std::vector<std::string>)> on_drop) {
  if (hwnd == nullptr || FAILED(OleInitialize(nullptr))) return false;
  auto* target = new FileDropTarget(std::move(on_drop));
  const HRESULT hr = RegisterDragDrop(hwnd, target);
  // On success the system holds its own reference until `RevokeDragDrop`.
  target->Release();
  if (FAILED(hr)) {
    OleUninitialize();
    return false;
  }
  return true;
}

void RevokeFileDrop(HWND hwnd) {
  RevokeDragDrop(hwnd);
  OleUninitialize();
}
