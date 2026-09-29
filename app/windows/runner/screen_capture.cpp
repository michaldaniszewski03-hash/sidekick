#include "screen_capture.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

namespace {

// Encodes a top-down 32-bit BGRA bitmap as JPEG with WIC.
std::vector<uint8_t> EncodeJpeg(const void* pixels, int width, int height,
                                float quality) {
  // Kept for the life of the process on purpose: releasing it from a static
  // destructor would run after COM has shut down.
  static IWICImagingFactory* factory = nullptr;
  if (!factory &&
      FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    factory = nullptr;
    return {};
  }

  const UINT stride = static_cast<UINT>(width) * 4;
  const UINT size = stride * static_cast<UINT>(height);
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(
          static_cast<UINT>(width), static_cast<UINT>(height),
          GUID_WICPixelFormat32bppBGRA, stride, size,
          static_cast<BYTE*>(const_cast<void*>(pixels)), &bitmap))) {
    return {};
  }

  // JPEG has no alpha: convert to 24-bit BGR first.
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(bitmap.Get(), GUID_WICPixelFormat24bppBGR,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return {};
  }

  ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};

  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                    &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
    return {};
  }

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (FAILED(encoder->CreateNewFrame(&frame, &props))) return {};

  PROPBAG2 option = {};
  wchar_t name[] = L"ImageQuality";
  option.pstrName = name;
  VARIANT value;
  VariantInit(&value);
  value.vt = VT_R4;
  value.fltVal = quality;
  props->Write(1, &option, &value);

  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (FAILED(frame->Initialize(props.Get())) ||
      FAILED(frame->SetSize(static_cast<UINT>(width),
                            static_cast<UINT>(height))) ||
      FAILED(frame->SetPixelFormat(&format)) ||
      FAILED(frame->WriteSource(converter.Get(), nullptr)) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
    return {};
  }

  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return {};
  HGLOBAL memory = nullptr;
  if (FAILED(GetHGlobalFromStream(stream.Get(), &memory))) return {};
  const size_t length = static_cast<size_t>(stat.cbSize.QuadPart);
  const auto* data = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!data) return {};
  std::vector<uint8_t> out(data, data + length);
  GlobalUnlock(memory);
  return out;
}

}  // namespace

std::vector<uint8_t> CaptureScreenJpeg(int max_width, float quality) {
  // The runner is per-monitor DPI aware, so these are physical pixels.
  const int width = GetSystemMetrics(SM_CXSCREEN);
  const int height = GetSystemMetrics(SM_CYSCREEN);
  if (width <= 0 || height <= 0) return {};

  int out_width = width;
  int out_height = height;
  if (max_width > 0 && width > max_width) {
    out_width = max_width;
    out_height = MulDiv(height, max_width, width);
  }

  HDC screen = GetDC(nullptr);
  if (!screen) return {};
  HDC memory = CreateCompatibleDC(screen);

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = out_width;
  info.bmiHeader.biHeight = -out_height;  // top-down rows
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP dib =
      CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);

  std::vector<uint8_t> jpeg;
  if (memory && dib && pixels) {
    HGDIOBJ previous = SelectObject(memory, dib);
    SetStretchBltMode(memory, HALFTONE);
    SetBrushOrgEx(memory, 0, 0, nullptr);
    StretchBlt(memory, 0, 0, out_width, out_height, screen, 0, 0, width,
               height, SRCCOPY | CAPTUREBLT);

    // The pointer isn't part of the captured image; draw it in.
    CURSORINFO cursor = {};
    cursor.cbSize = sizeof(cursor);
    if (GetCursorInfo(&cursor) && (cursor.flags & CURSOR_SHOWING)) {
      ICONINFO icon = {};
      if (GetIconInfo(cursor.hCursor, &icon)) {
        const int x = MulDiv(cursor.ptScreenPos.x - static_cast<int>(icon.xHotspot),
                             out_width, width);
        const int y = MulDiv(cursor.ptScreenPos.y - static_cast<int>(icon.yHotspot),
                             out_height, height);
        DrawIconEx(memory, x, y, cursor.hCursor, 0, 0, 0, nullptr, DI_NORMAL);
        if (icon.hbmMask) DeleteObject(icon.hbmMask);
        if (icon.hbmColor) DeleteObject(icon.hbmColor);
      }
    }
    GdiFlush();

    // GDI leaves the alpha byte at 0; make every pixel opaque.
    auto* bgra = static_cast<uint8_t*>(pixels);
    const size_t count = static_cast<size_t>(out_width) * out_height;
    for (size_t i = 0; i < count; i++) bgra[i * 4 + 3] = 0xFF;

    jpeg = EncodeJpeg(pixels, out_width, out_height, quality);
    SelectObject(memory, previous);
  }

  if (dib) DeleteObject(dib);
  if (memory) DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  return jpeg;
}
