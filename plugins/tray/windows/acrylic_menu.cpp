#include "acrylic_menu.h"

#include <algorithm>
#include <cmath>
#include <utility>
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <limits>
#include <dwmapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <shellscalingapi.h>
#include <windowsx.h>

namespace tray {
namespace {
using namespace Gdiplus;
using Microsoft::WRL::ComPtr;

constexpr wchar_t kClassName[] = L"FlClashZ.AcrylicTrayMenu";
constexpr DWORD kAcrylicTint = 0x65000000;  // AABBGGRR; black, alpha 101.
constexpr int kPadding = 4;
constexpr int kInset = 10;
constexpr int kIcon = 16;
constexpr int kGap = 10;
constexpr int kDetailGap = 16;
constexpr int kRowHeight = 32;
constexpr int kSeparatorHeight = 9;

struct AccentPolicy {
  int state;
  int flags;
  DWORD color;
  int animation;
};
struct CompositionData {
  int attribute;
  void* data;
  SIZE_T size;
};
using SetCompositionFn = BOOL(WINAPI*)(HWND, CompositionData*);
using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);

SetCompositionFn AcrylicApi() {
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  const HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (!ntdll || !user32) return nullptr;
  const auto version = reinterpret_cast<RtlGetVersionFn>(
      GetProcAddress(ntdll, "RtlGetVersion"));
  OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (!version || version(&info) != 0 || info.dwBuildNumber < 22000)
    return nullptr;
  BOOL composition = FALSE;
  if (FAILED(DwmIsCompositionEnabled(&composition)) || !composition)
    return nullptr;
  HIGHCONTRASTW contrast{};
  contrast.cbSize = sizeof(contrast);
  BOOL reader = FALSE;
  if (!SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0)
      || (contrast.dwFlags & HCF_HIGHCONTRASTON) ||
      (SystemParametersInfoW(SPI_GETSCREENREADER, 0, &reader, 0) && reader))
    return nullptr;
  DWORD transparency = 1;
  DWORD size = sizeof(transparency);
  if (RegGetValueW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"EnableTransparency", RRF_RT_REG_DWORD, nullptr, &transparency,
      &size) == ERROR_SUCCESS && transparency == 0)
    return nullptr;
  return reinterpret_cast<SetCompositionFn>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
}

bool ApplyAcrylic(HWND window, SetCompositionFn set_composition) {
  const DWORD corner = 3;  // DWMWCP_ROUNDSMALL
  const DWORD border = 0xfffffffe;  // DWMWA_COLOR_NONE
  if (FAILED(DwmSetWindowAttribute(window,
      static_cast<DWMWINDOWATTRIBUTE>(33), &corner, sizeof(corner))) ||
      FAILED(DwmSetWindowAttribute(window,
      static_cast<DWMWINDOWATTRIBUTE>(34), &border, sizeof(border))))
    return false;
  const MARGINS margins{-1, -1, -1, -1};
  if (FAILED(DwmExtendFrameIntoClientArea(window, &margins))) return false;
  AccentPolicy policy{4, 0, kAcrylicTint, 0};
  CompositionData data{19, &policy, sizeof(policy)};
  return set_composition(window, &data) != FALSE;
}

void RoundFill(Graphics& graphics, const RectF& r, REAL radius, Color color) {
  const REAL d = radius * 2;
  GraphicsPath path;
  path.AddArc(r.X, r.Y, d, d, 180, 90);
  path.AddArc(r.GetRight() - d, r.Y, d, d, 270, 90);
  path.AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0, 90);
  path.AddArc(r.X, r.GetBottom() - d, d, d, 90, 90);
  path.CloseFigure();
  SolidBrush brush(color);
  graphics.FillPath(&brush, &path);
}

void DrawIcon(Graphics& graphics, const AcrylicRow& row, REAL x, REAL y,
              REAL size, Color color) {
  if (row.icon.empty() && !row.checked) return;
  const auto saved = graphics.Save();
  graphics.TranslateTransform(x, y);
  graphics.ScaleTransform(size / 16, size / 16);
  Pen pen(color, 1.3f);
  pen.SetLineJoin(LineJoinRound);
  pen.SetStartCap(LineCapRound);
  pen.SetEndCap(LineCapRound);
  if (row.checked) {
    const PointF points[] = {{2, 8}, {6, 12}, {14, 4}};
    graphics.DrawLines(&pen, points, 3);
  } else if (row.icon == "show") {
    graphics.DrawRectangle(&pen, 1.5f, 2.5f, 13.0f, 11.0f);
    graphics.DrawLine(&pen, 1.5f, 5.5f, 14.5f, 5.5f);
  } else if (row.icon == "start") {
    const PointF points[] = {{4, 2}, {13, 8}, {4, 14}, {4, 2}};
    graphics.DrawLines(&pen, points, 4);
  } else if (row.icon == "stop") {
    graphics.DrawRectangle(&pen, 3.0f, 3.0f, 10.0f, 10.0f);
  } else if (row.icon == "restart") {
    // Clockwise reload arrow: the arrowhead meets the arc endpoint at 330°.
    graphics.DrawArc(&pen, 2.0f, 2.0f, 12.0f, 12.0f, 15.0f, 315.0f);
    const PointF points[] = {{13.2f, 1.3f}, {13.2f, 5.0f}, {9.5f, 5.0f}};
    graphics.DrawLines(&pen, points, 3);
  } else if (row.icon == "exit") {
    const PointF door[] = {{6, 2}, {2, 2}, {2, 14}, {6, 14}};
    graphics.DrawLines(&pen, door, 4);
    graphics.DrawLine(&pen, 5.0f, 8.0f, 14.0f, 8.0f);
    const PointF arrow[] = {{10, 4}, {14, 8}, {10, 12}};
    graphics.DrawLines(&pen, arrow, 3);
  }
  graphics.Restore(saved);
}
}  // namespace

struct AcrylicMenu::Render {
  ULONG_PTR token = 0;
  std::vector<BYTE> text_pixels;
  Render() {
    GdiplusStartupInput input;
    if (GdiplusStartup(&token, &input, nullptr) != Ok) token = 0;
  }
  ~Render() {
    if (token) GdiplusShutdown(token);
  }
};

AcrylicMenu::AcrylicMenu() = default;
AcrylicMenu::~AcrylicMenu() { Close(); }

int AcrylicMenu::Scale(int dip) const {
  return MulDiv(dip, static_cast<int>(dpi_), 96);
}

bool AcrylicMenu::Open(HWND owner, POINT anchor,
                       const std::vector<AcrylicRow>& rows,
                       std::function<void(int)> selected) {
  Close();
  const auto acrylic = AcrylicApi();
  if (!acrylic || rows.empty()) return false;
  if (!render_) render_ = std::make_unique<Render>();
  if (!render_->token) return false;
  const HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return false;
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y)))
    dpi_x = 96;
  dpi_ = dpi_x;
  ComPtr<IDWriteFactory> write;
  if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
      __uuidof(IDWriteFactory),
      reinterpret_cast<IUnknown**>(write.GetAddressOf())))) return false;
  ComPtr<IDWriteFontCollection> fonts;
  if (FAILED(write->GetSystemFontCollection(fonts.GetAddressOf()))) return false;
  UINT32 family_index = 0;
  BOOL family_exists = FALSE;
  if (FAILED(fonts->FindFamilyName(L"Segoe UI Variable Text", &family_index,
                                 &family_exists))) return false;
  const wchar_t* family = family_exists ? L"Segoe UI Variable Text" : L"Segoe UI";
  ComPtr<IDWriteTextFormat> format;
  // Layout and rendering both use physical pixels at a 96-DPI render target.
  if (FAILED(write->CreateTextFormat(family, fonts.Get(),
      DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL,
      DWRITE_FONT_STRETCH_NORMAL, 14.0f * static_cast<float>(dpi_) / 96.0f,
      L"", format.GetAddressOf()))) return false;
  if (FAILED(format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)) ||
      FAILED(format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)))
    return false;
  const auto measure = [&](const std::wstring& text, int& width) {
    if (text.empty()) return true;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(write->CreateTextLayout(text.c_str(),
        static_cast<UINT32>(text.size()), format.Get(), 32768.0f,
        static_cast<float>(Scale(kRowHeight)), layout.GetAddressOf())))
      return false;
    DWRITE_TEXT_METRICS metrics{};
    if (FAILED(layout->GetMetrics(&metrics))) return false;
    width = (std::max)(width,
        static_cast<int>(std::ceil(metrics.widthIncludingTrailingWhitespace)));
    return true;
  };
  int detail_width = 0;
  label_width_ = 0;
  height_ = 2 * Scale(kPadding);
  for (const auto& row : rows) {
    height_ += Scale(row.separator ? kSeparatorHeight : kRowHeight);
    if (!row.separator &&
        (!measure(row.label, label_width_) || !measure(row.detail, detail_width)))
      return false;
  }
  // Fit the longest translated label and optional shortcut column, no
  // fixed minimum width. Allow two extra DIP for glyph overhang.
  width_ = 2 * Scale(kPadding + kInset) + Scale(kIcon + kGap + 2) +
      label_width_ + (detail_width ? Scale(kDetailGap) + detail_width : 0);
  if (width_ > info.rcWork.right - info.rcWork.left ||
      height_ > info.rcWork.bottom - info.rcWork.top) return false;

  rows_ = rows;
  selected_ = std::move(selected);
  bounds_.clear();
  int top = Scale(kPadding);
  for (const auto& row : rows_) {
    const int bottom = top + Scale(row.separator ? kSeparatorHeight : kRowHeight);
    bounds_.push_back(RECT{Scale(kPadding), top, width_ - Scale(kPadding), bottom});
    top = bottom;
  }
  // Text does not change on hover. Rasterize once, before opening the window.
  // Keep the existing GDI+ icons, highlights and acrylic composition untouched.
  // WIC requires COM on this thread; balance successful initialization only.
  struct ComScope {
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~ComScope() { if (SUCCEEDED(result)) CoUninitialize(); }
  } com;
  if (FAILED(com.result) && com.result != RPC_E_CHANGED_MODE) return false;
  ComPtr<IWICImagingFactory> wic;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.GetAddressOf())))) return false;
  ComPtr<IWICBitmap> text_bitmap;
  if (FAILED(wic->CreateBitmap(static_cast<UINT>(width_),
      static_cast<UINT>(height_), GUID_WICPixelFormat32bppPBGRA,
      WICBitmapCacheOnLoad, text_bitmap.GetAddressOf()))) return false;
  ComPtr<ID2D1Factory> d2d;
  if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                              d2d.GetAddressOf()))) return false;
  ComPtr<ID2D1RenderTarget> target;
  const auto properties = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                       D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
  if (FAILED(d2d->CreateWicBitmapRenderTarget(text_bitmap.Get(),
      properties, target.GetAddressOf()))) return false;
  target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  ComPtr<ID2D1SolidColorBrush> text_brush;
  if (FAILED(target->CreateSolidColorBrush(
      D2D1::ColorF(D2D1::ColorF::White), text_brush.GetAddressOf()))) return false;
  const auto draw = [&](const std::wstring& text, float x, float y,
                        float width, float height, bool trailing, float alpha) {
    if (text.empty()) return true;
    if (width <= 0.0f || height <= 0.0f) return false;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(write->CreateTextLayout(text.c_str(),
        static_cast<UINT32>(text.size()), format.Get(), width, height,
        layout.GetAddressOf())) ||
        FAILED(layout->SetTextAlignment(trailing ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                                 : DWRITE_TEXT_ALIGNMENT_LEADING)))
      return false;
    text_brush->SetOpacity(alpha);
    target->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), text_brush.Get());
    return true;
  };
  target->BeginDraw();
  target->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  bool text_ok = true;
  for (size_t i = 0; i < rows_.size() && text_ok; ++i) {
    const auto& row = rows_[i];
    if (row.separator) continue;
    const auto& rect = bounds_[i];
    const float x = static_cast<float>(rect.left + Scale(kInset) +
                                       Scale(kIcon + kGap));
    const float y = static_cast<float>(rect.top);
    const float h = static_cast<float>(rect.bottom - rect.top);
    const float label_width = static_cast<float>(label_width_ + Scale(2));
    text_ok = draw(row.label, x, y, label_width, h, false,
                   row.enabled ? 1.0f : 115.0f / 255.0f);
    if (text_ok && !row.detail.empty()) {
      const float detail_x = x + static_cast<float>(label_width_ + Scale(kDetailGap));
      const float detail_end = static_cast<float>(rect.right - Scale(kInset));
      text_ok = draw(row.detail, detail_x, y, detail_end - detail_x, h, true,
                     row.enabled ? 190.0f / 255.0f : 100.0f / 255.0f);
    }
  }
  const HRESULT draw_result = target->EndDraw();
  if (!text_ok || FAILED(draw_result)) return false;
  // Release the render target before reading the premultiplied text bitmap.
  text_brush.Reset();
  target.Reset();
  const size_t stride = static_cast<size_t>(width_) * 4;
  const size_t bytes = stride * static_cast<size_t>(height_);
  if (stride > (std::numeric_limits<UINT>::max)() ||
      bytes > (std::numeric_limits<UINT>::max)()) return false;
  render_->text_pixels.resize(bytes);
  if (FAILED(text_bitmap->CopyPixels(nullptr, static_cast<UINT>(stride),
      static_cast<UINT>(bytes), render_->text_pixels.data()))) {
    render_->text_pixels.clear();
    return false;
  }

  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW wc{};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = instance;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return false;

  const int left = (std::clamp)(static_cast<int>(anchor.x) - width_,
      static_cast<int>(info.rcWork.left), static_cast<int>(info.rcWork.right) - width_);
  const int above = static_cast<int>(anchor.y) - height_ - Scale(4);
  const int below = static_cast<int>(anchor.y) + Scale(4);
  const int y = (std::clamp)(above >= info.rcWork.top ? above : below,
      static_cast<int>(info.rcWork.top), static_cast<int>(info.rcWork.bottom) - height_);
  SetForegroundWindow(owner);
  window_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kClassName,
      L"FlClashZ", WS_POPUP, left, y, width_, height_, owner, nullptr,
      instance, this);
  if (!window_) return false;
  if (!ApplyAcrylic(window_, acrylic)) {
    Close();
    return false;
  }
  ShowWindow(window_, SW_SHOW);
  if (!window_) return false;
  SetForegroundWindow(window_);
  if (!window_) return false;
  SetFocus(window_);
  if (!window_ || GetForegroundWindow() != window_) {
    Close();
    return false;
  }
  SetCapture(window_);
  if (!window_ || GetCapture() != window_) {
    Close();
    return false;
  }
  InvalidateRect(window_, nullptr, FALSE);
  return true;
}

void AcrylicMenu::Close() {
  const HWND old = window_;
  window_ = nullptr;
  hover_ = pressed_ = -1;
  selected_ = {};
  if (old) {
    if (GetCapture() == old) ReleaseCapture();
    DestroyWindow(old);
  }
}

int AcrylicMenu::Hit(POINT point) const {
  for (size_t i = 0; i < bounds_.size(); ++i) {
    if (!rows_[i].separator && rows_[i].enabled &&
        PtInRect(&bounds_[i], point)) return static_cast<int>(i);
  }
  return -1;
}

void AcrylicMenu::Select(int index) {
  if (index < 0 || index >= static_cast<int>(rows_.size())) return;
  const auto& row = rows_[static_cast<size_t>(index)];
  if (row.separator || !row.enabled || row.id == 0) return;
  const int id = row.id;
  auto callback = selected_;
  Close();
  if (callback) callback(id);
}

void AcrylicMenu::MoveSelection(int direction) {
  const int count = static_cast<int>(rows_.size());
  if (!count) return;
  int next = hover_;
  if (next < 0) next = direction > 0 ? count - 1 : 0;
  for (int step = 0; step < count; ++step) {
    next = (next + direction + count) % count;
    if (!rows_[static_cast<size_t>(next)].separator &&
        rows_[static_cast<size_t>(next)].enabled) {
      hover_ = next;
      InvalidateRect(window_, nullptr, FALSE);
      break;
    }
  }
}

void AcrylicMenu::Paint(HWND window) {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  if (!dc) return;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width_;
  info.bmiHeader.biHeight = -height_;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  HDC memory = CreateCompatibleDC(dc);
  if (bitmap && memory && pixels) {
    {
      Bitmap surface(width_, height_, width_ * 4, PixelFormat32bppPARGB,
                     static_cast<BYTE*>(pixels));
      Graphics graphics(&surface);
      graphics.Clear(Color(0, 0, 0, 0));
      graphics.SetSmoothingMode(SmoothingModeAntiAlias);
      for (size_t i = 0; i < rows_.size(); ++i) {
        const auto& row = rows_[i];
        const auto& rect = bounds_[i];
        const REAL x = static_cast<REAL>(rect.left);
        const REAL y = static_cast<REAL>(rect.top);
        const REAL w = static_cast<REAL>(rect.right - rect.left);
        const REAL h = static_cast<REAL>(rect.bottom - rect.top);
        if (row.separator) {
          Pen separator(Color(42, 255, 255, 255), 1.0f);
          graphics.DrawLine(&separator, x + static_cast<REAL>(Scale(8)), y + h / 2,
                            x + w - static_cast<REAL>(Scale(8)), y + h / 2);
          continue;
        }
        if (static_cast<int>(i) == hover_)
          RoundFill(graphics, RectF(x, y, w, h), static_cast<REAL>(Scale(5)),
                    Color(static_cast<BYTE>(pressed_ == hover_ ? 38 : 24), 255, 255, 255));
        const Color foreground(static_cast<BYTE>(row.enabled ? 255 : 115), 255, 255, 255);
        const REAL icon = static_cast<REAL>(Scale(kIcon));
        const REAL inset = static_cast<REAL>(Scale(kInset));
        DrawIcon(graphics, row, x + inset, y + (h - icon) / 2, icon, foreground);

      }
    }
    // Source-over composition of two premultiplied BGRA layers. Preserve
    // the text's grayscale coverage (including alpha) on the acrylic surface.
    auto* destination = static_cast<BYTE*>(pixels);
    const auto& text = render_->text_pixels;
    const size_t expected = static_cast<size_t>(width_) *
                            static_cast<size_t>(height_) * 4;
    if (text.size() == expected) {
      for (size_t i = 0; i < text.size(); i += 4) {
        const unsigned alpha = text[i + 3];
        if (!alpha) continue;
        const unsigned inverse = 255 - alpha;
        for (size_t channel = 0; channel < 4; ++channel) {
          const unsigned value = text[i + channel] +
              (destination[i + channel] * inverse + 127) / 255;
          destination[i + channel] = static_cast<BYTE>((std::min)(value, 255u));
        }
      }
    }
    const HGDIOBJ previous = SelectObject(memory, bitmap);
    BitBlt(dc, 0, 0, width_, height_, memory, 0, 0, SRCCOPY);
    SelectObject(memory, previous);
  }
  if (memory) DeleteDC(memory);
  if (bitmap) DeleteObject(bitmap);
  EndPaint(window, &paint);
}

LRESULT CALLBACK AcrylicMenu::WindowProc(HWND window, UINT message, WPARAM wp,
                                         LPARAM lp) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lp);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<AcrylicMenu*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (!self) return DefWindowProcW(window, message, wp, lp);
  if (message == WM_NCDESTROY) {
    SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    if (self->window_ == window) self->window_ = nullptr;
    return DefWindowProcW(window, message, wp, lp);
  }
  return self->Handle(window, message, wp, lp);
}

LRESULT AcrylicMenu::Handle(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: Paint(window); return 0;
    case WM_MOUSEMOVE: {
      const int hit = Hit(POINT{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
      if (hit != hover_) {
        hover_ = hit;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN: {
      const POINT point{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      RECT client{};
      GetClientRect(window, &client);
      if (!PtInRect(&client, point)) Close();
      else {
        pressed_ = Hit(point);
        hover_ = pressed_;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONUP:
    case WM_RBUTTONUP: {
      const int hit = Hit(POINT{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
      if (hit >= 0 && hit == pressed_) Select(hit);
      else {
        pressed_ = -1;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_KEYDOWN:
      switch (wp) {
        case VK_ESCAPE: Close(); return 0;
        case VK_UP: MoveSelection(-1); return 0;
        case VK_DOWN: MoveSelection(1); return 0;
        case VK_HOME: hover_ = -1; MoveSelection(1); return 0;
        case VK_END: hover_ = -1; MoveSelection(-1); return 0;
        case VK_RETURN:
        case VK_SPACE: Select(hover_); return 0;
      }
      break;
    case WM_ACTIVATE:
      if (window_ == window && LOWORD(wp) == WA_INACTIVE) Close();
      break;
    case WM_CAPTURECHANGED:
      if (window_ == window && reinterpret_cast<HWND>(lp) != window) Close();
      return 0;
    case WM_CANCELMODE:
    case WM_DPICHANGED:
    case WM_DISPLAYCHANGE:
    case WM_CLOSE:
      if (window_ == window) Close();
      return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}

}  // namespace tray
