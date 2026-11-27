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
#include <shellscalingapi.h>
#include <windowsx.h>

namespace tray {
namespace {
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

// All geometry is built in physical pixels, at a 96-DPI render target.
float SnapStroke(float value, float stroke) {
  const float phase = std::fmod(stroke, 2.0f) * 0.5f;
  return std::round(value - phase) + phase;
}

float IconStroke(float size) {
  return (std::max)(1.0f, std::round(1.3f * size / 16.0f));
}

// A common 16-unit vector grid, with balanced optical bounds and equal stroke
// weight. Snap each control point rather than translating a rasterized icon.
HRESULT CreateIconGeometry(ID2D1Factory* factory, const AcrylicRow& row,
                           float x, float y, float size, float stroke,
                           ID2D1PathGeometry** result) {
  if (row.icon.empty() && !row.checked) return S_OK;
  if (!row.checked && row.icon != "show" && row.icon != "start" &&
      row.icon != "stop" && row.icon != "restart" && row.icon != "exit")
    return S_OK;

  ComPtr<ID2D1PathGeometry> path;
  HRESULT hr = factory->CreatePathGeometry(path.GetAddressOf());
  if (FAILED(hr)) return hr;
  ComPtr<ID2D1GeometrySink> sink;
  hr = path->Open(sink.GetAddressOf());
  if (FAILED(hr)) return hr;
  const float scale = size / 16.0f;
  const auto point = [&](float px, float py) {
    return D2D1::Point2F(SnapStroke(x + px * scale, stroke),
                         SnapStroke(y + py * scale, stroke));
  };
  const auto begin = [&](float px, float py) {
    sink->BeginFigure(point(px, py), D2D1_FIGURE_BEGIN_HOLLOW);
  };
  const auto line = [&](float px, float py) { sink->AddLine(point(px, py)); };
  const auto end = [&](bool closed = false) {
    sink->EndFigure(closed ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN);
  };
  if (row.checked) {
    begin(2, 8); line(6, 12); line(14, 4); end();
  } else if (row.icon == "show") {
    begin(2, 3); line(14, 3); line(14, 13); line(2, 13); end(true);
    begin(2, 6); line(14, 6); end();
  } else if (row.icon == "start") {
    begin(3, 2); line(13, 8); line(3, 14); end(true);
  } else if (row.icon == "stop") {
    // Match the Flutter circle-stop glyph on the native 16-unit grid.
    begin(2.13f, 8);
    sink->AddArc(D2D1::ArcSegment(point(13.87f, 8),
        D2D1::SizeF(5.87f * scale, 5.87f * scale), 0.0f,
        D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
    sink->AddArc(D2D1::ArcSegment(point(2.13f, 8),
        D2D1::SizeF(5.87f * scale, 5.87f * scale), 0.0f,
        D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
    end(true);
    begin(5.67f, 5.67f); line(10.33f, 5.67f);
    line(10.33f, 10.33f); line(5.67f, 10.33f); end(true);
  } else if (row.icon == "restart") {
    // Match the Flutter clockwise rotate arrow.
    begin(13, 10.33f);
    sink->AddArc(D2D1::ArcSegment(point(13, 5.67f),
        D2D1::SizeF(5.53f * scale, 5.53f * scale), 0.0f,
        D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_LARGE));
    end();
    begin(13, 2.33f); line(13, 5.67f); line(9.67f, 5.67f); end();
  } else if (row.icon == "exit") {
    begin(6, 2); line(2, 2); line(2, 14); line(6, 14); end();
    begin(5, 8); line(14, 8); end();
    begin(10, 4); line(14, 8); line(10, 12); end();
  }
  hr = sink->Close();
  if (FAILED(hr)) return hr;
  *result = path.Detach();
  return S_OK;
}

struct ComScope {
  HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ~ComScope() { if (SUCCEEDED(result)) CoUninitialize(); }
  bool valid() const { return SUCCEEDED(result) || result == RPC_E_CHANGED_MODE; }
};
}  // namespace

struct AcrylicMenu::Render {
  struct Row {
    ComPtr<IDWriteTextLayout> label;
    ComPtr<IDWriteTextLayout> detail;
    ComPtr<ID2D1PathGeometry> icon;
    D2D1_POINT_2F label_origin{};
    D2D1_POINT_2F detail_origin{};
  };

  // Declare COM scope first so every COM object is released before uninit.
  ComScope com;
  ComPtr<IWICImagingFactory> wic;
  ComPtr<ID2D1Factory> d2d;
  ComPtr<ID2D1StrokeStyle> stroke_style;
  std::vector<Row> rows;
  std::vector<BYTE> pixels;
  int painted_hover = -2;
  int painted_pressed = -2;
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
  const HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return false;
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y)))
    dpi_x = 96;
  dpi_ = dpi_x;
  auto render = std::make_unique<Render>();
  if (!render->com.valid()) return false;
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
      DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL,
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
  // Cache layouts and vector geometries for the lifetime of this popup.
  // Every frame is composed by Direct2D/DirectWrite into one PBGRA bitmap.
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(render->wic.GetAddressOf())))) return false;
  if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                              render->d2d.GetAddressOf()))) return false;
  const auto stroke_properties = D2D1::StrokeStyleProperties(
      D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
      D2D1_LINE_JOIN_ROUND);
  if (FAILED(render->d2d->CreateStrokeStyle(stroke_properties, nullptr, 0,
      render->stroke_style.GetAddressOf()))) return false;
  const auto layout = [&](const std::wstring& text, float width, float height,
                          bool trailing, IDWriteTextLayout** result) {
    if (text.empty()) return true;
    if (width <= 0.0f || height <= 0.0f) return false;
    ComPtr<IDWriteTextLayout> value;
    if (FAILED(write->CreateTextLayout(text.c_str(),
        static_cast<UINT32>(text.size()), format.Get(), width, height,
        value.GetAddressOf())) ||
        FAILED(value->SetTextAlignment(trailing ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                                 : DWRITE_TEXT_ALIGNMENT_LEADING)))
      return false;
    *result = value.Detach();
    return true;
  };
  render->rows.resize(rows_.size());
  for (size_t i = 0; i < rows_.size(); ++i) {
    const auto& row = rows_[i];
    if (row.separator) continue;
    const auto& rect = bounds_[i];
    auto& visual = render->rows[i];
    const float x = static_cast<float>(rect.left + Scale(kInset) +
                                       Scale(kIcon + kGap));
    const float y = static_cast<float>(rect.top);
    const float h = static_cast<float>(rect.bottom - rect.top);
    const float label_width = static_cast<float>(label_width_ + Scale(2));
    visual.label_origin = D2D1::Point2F(x, y);
    if (!layout(row.label, label_width, h, false,
                visual.label.GetAddressOf())) return false;
    if (!row.detail.empty()) {
      const float detail_x = x + static_cast<float>(label_width_ + Scale(kDetailGap));
      const float detail_end = static_cast<float>(rect.right - Scale(kInset));
      visual.detail_origin = D2D1::Point2F(detail_x, y);
      if (!layout(row.detail, detail_end - detail_x, h, true,
                  visual.detail.GetAddressOf())) return false;
    }
    const float icon = static_cast<float>(Scale(kIcon));
    if (FAILED(CreateIconGeometry(render->d2d.Get(), row,
        static_cast<float>(rect.left + Scale(kInset)), y + (h - icon) / 2.0f,
        icon, IconStroke(icon), visual.icon.GetAddressOf()))) return false;
  }
  // Layouts retain their own references; release local COM objects before
  // the popup can close synchronously during window creation or activation.
  format.Reset();
  fonts.Reset();
  write.Reset();
  render_ = std::move(render);
  // Validate the first frame before showing the window; the caller can still
  // fall back to the system menu if Direct2D/WIC initialization fails.
  if (!RenderFrame()) {
    Close();
    return false;
  }

  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW wc{};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = instance;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = kClassName;
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    Close();
    return false;
  }

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
  if (!window_) {
    Close();
    return false;
  }
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
  render_.reset();
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

bool AcrylicMenu::RenderFrame() {
  if (!render_ || width_ <= 0 || height_ <= 0) return false;
  auto& render = *render_;
  if (render.painted_hover == hover_ && render.painted_pressed == pressed_)
    return true;

  const size_t stride = static_cast<size_t>(width_) * 4;
  const size_t bytes = stride * static_cast<size_t>(height_);
  if (stride > (std::numeric_limits<UINT>::max)() ||
      bytes > (std::numeric_limits<UINT>::max)()) return false;
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(render.wic->CreateBitmap(static_cast<UINT>(width_),
      static_cast<UINT>(height_), GUID_WICPixelFormat32bppPBGRA,
      WICBitmapCacheOnLoad, bitmap.GetAddressOf()))) return false;
  ComPtr<ID2D1RenderTarget> target;
  const auto properties = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                       D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
  if (FAILED(render.d2d->CreateWicBitmapRenderTarget(bitmap.Get(),
      properties, target.GetAddressOf()))) return false;
  target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  ComPtr<ID2D1SolidColorBrush> brush;
  if (FAILED(target->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White),
      brush.GetAddressOf()))) return false;

  target->BeginDraw();
  target->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  const float icon_stroke = IconStroke(static_cast<float>(Scale(kIcon)));
  for (size_t i = 0; i < rows_.size(); ++i) {
    const auto& row = rows_[i];
    const auto& visual = render.rows[i];
    const auto& rect = bounds_[i];
    const float x = static_cast<float>(rect.left);
    const float y = static_cast<float>(rect.top);
    const float right = static_cast<float>(rect.right);
    const float bottom = static_cast<float>(rect.bottom);
    const float h = bottom - y;
    if (row.separator) {
      brush->SetOpacity(42.0f / 255.0f);
      const float mid = SnapStroke(y + h / 2.0f, 1.0f);
      const float inset = static_cast<float>(Scale(8));
      target->DrawLine(D2D1::Point2F(x + inset, mid),
          D2D1::Point2F(right - inset, mid), brush.Get(), 1.0f);
      continue;
    }
    if (static_cast<int>(i) == hover_) {
      brush->SetOpacity((pressed_ == hover_ ? 38.0f : 24.0f) / 255.0f);
      const float radius = static_cast<float>(Scale(5));
      target->FillRoundedRectangle(D2D1::RoundedRect(
          D2D1::RectF(x, y, right, bottom), radius, radius), brush.Get());
    }
    brush->SetOpacity(row.enabled ? 1.0f : 115.0f / 255.0f);
    if (visual.icon)
      target->DrawGeometry(visual.icon.Get(), brush.Get(), icon_stroke,
                           render.stroke_style.Get());
    if (visual.label)
      target->DrawTextLayout(visual.label_origin, visual.label.Get(), brush.Get());
    if (visual.detail) {
      brush->SetOpacity((row.enabled ? 190.0f : 100.0f) / 255.0f);
      target->DrawTextLayout(visual.detail_origin, visual.detail.Get(), brush.Get());
    }
  }
  const HRESULT draw_result = target->EndDraw();
  if (FAILED(draw_result)) return false;
  brush.Reset();
  target.Reset();
  std::vector<BYTE> pixels(bytes);
  if (FAILED(bitmap->CopyPixels(nullptr, static_cast<UINT>(stride),
      static_cast<UINT>(bytes), pixels.data()))) return false;
  render.pixels.swap(pixels);
  render.painted_hover = hover_;
  render.painted_pressed = pressed_;
  return true;
}

void AcrylicMenu::Paint(HWND window) {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  if (!dc) return;
  // GDI is used only to present the finished Direct2D bitmap to DWM.
  // No GDI/GDI+ drawing or manual blending of separate layers occurs here.
  const bool ready = RenderFrame();
  if (render_ && !render_->pixels.empty()) {
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
      std::copy(render_->pixels.begin(), render_->pixels.end(),
                static_cast<BYTE*>(pixels));
      const HGDIOBJ previous = SelectObject(memory, bitmap);
      if (previous && previous != HGDI_ERROR) {
        BitBlt(dc, 0, 0, width_, height_, memory, 0, 0, SRCCOPY);
        SelectObject(memory, previous);
      }
    }
    if (memory) DeleteDC(memory);
    if (bitmap) DeleteObject(bitmap);
  }
  EndPaint(window, &paint);
  if (!ready) Close();
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
