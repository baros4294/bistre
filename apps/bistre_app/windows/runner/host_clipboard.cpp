#include "host_clipboard.h"

#include <cstdint>
#include <cstring>
#include <vector>

namespace {

// Most pixels of a copied picture (Dart scales a larger one down first).
constexpr int64_t kMaxCopiedPixels = 4096LL * 4096;

const std::vector<uint8_t>* BytesArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : std::get_if<std::vector<uint8_t>>(&it->second);
}

int64_t IntArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return 0;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  return 0;
}

// A bottom-up 32-bit BGRA `BITMAPV5HEADER` bitmap of `rgba`, or null when out of memory.
HGLOBAL DibV5(const std::vector<uint8_t>& rgba, int64_t width, int64_t height) {
  BITMAPV5HEADER header{};
  header.bV5Size = sizeof(header);
  header.bV5Width = static_cast<LONG>(width);
  header.bV5Height = static_cast<LONG>(height);
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5SizeImage = static_cast<DWORD>(rgba.size());
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;
  header.bV5CSType = LCS_sRGB;
  header.bV5Intent = LCS_GM_IMAGES;
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, sizeof(header) + rgba.size());
  if (mem == nullptr) return nullptr;
  auto* out = static_cast<uint8_t*>(GlobalLock(mem));
  if (out == nullptr) {
    GlobalFree(mem);
    return nullptr;
  }
  std::memcpy(out, &header, sizeof(header));
  uint8_t* pixels = out + sizeof(header);
  const size_t stride = static_cast<size_t>(width) * 4;
  for (int64_t y = 0; y < height; ++y) {
    const uint8_t* src = rgba.data() + static_cast<size_t>(height - 1 - y) * stride;
    uint8_t* dst = pixels + static_cast<size_t>(y) * stride;
    for (size_t x = 0; x < stride; x += 4) {
      dst[x] = src[x + 2];
      dst[x + 1] = src[x + 1];
      dst[x + 2] = src[x];
      dst[x + 3] = src[x + 3];
    }
  }
  GlobalUnlock(mem);
  return mem;
}

HGLOBAL GlobalBytes(const std::vector<uint8_t>& bytes) {
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (mem == nullptr) return nullptr;
  void* out = GlobalLock(mem);
  if (out == nullptr) {
    GlobalFree(mem);
    return nullptr;
  }
  std::memcpy(out, bytes.data(), bytes.size());
  GlobalUnlock(mem);
  return mem;
}

}  // namespace

bool CopyPictureToClipboard(HWND owner, const flutter::EncodableMap& args) {
  const auto* rgba = BytesArg(args, "rgba");
  const auto* png = BytesArg(args, "png");
  const int64_t width = IntArg(args, "width");
  const int64_t height = IntArg(args, "height");
  if (rgba == nullptr || width <= 0 || height <= 0 || width * height > kMaxCopiedPixels ||
      rgba->size() != static_cast<size_t>(width * height * 4)) {
    return false;
  }
  HGLOBAL dib = DibV5(*rgba, width, height);
  if (dib == nullptr) return false;
  HGLOBAL png_mem = png != nullptr && !png->empty() ? GlobalBytes(*png) : nullptr;
  if (!OpenClipboard(owner)) {
    GlobalFree(dib);
    if (png_mem != nullptr) GlobalFree(png_mem);
    return false;
  }
  EmptyClipboard();
  // The clipboard owns each block it accepts; one it refuses stays ours to free.
  const bool copied = SetClipboardData(CF_DIBV5, dib) != nullptr;
  if (!copied) GlobalFree(dib);
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_mem != nullptr && (png_format == 0 || SetClipboardData(png_format, png_mem) == nullptr)) {
    GlobalFree(png_mem);
  }
  CloseClipboard();
  return copied;
}
