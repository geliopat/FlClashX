#include "acrylic_menu.h"

#include <algorithm>
#include <cmath>
#include <utility>
#include <dwmapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <shellscalingapi.h>
#include <windowsx.h>

namespace tray {
namespace {
using namespace Gdiplus;

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
    graphics.DrawArc(&pen, 2.0f, 2.0f, 12.0f, 12.0f, -45.0f, 300.0f);
    const PointF points[] = {{14, 1}, {14, 6}, {9, 6}};
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
  std::unique_ptr<Font> font;
  Render() {
    GdiplusStartupInput input;
    if (GdiplusStartup(&token, &input, nullptr) != Ok) token = 0;
  }
  ~Render() {
    font.reset();
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
  render_->font = std::make_unique<Font>(L"Segoe UI Variable Text",
      static_cast<REAL>(Scale(14)), FontStyleRegular, UnitPixel);
  if (render_->font->GetLastStatus() != Ok) {
    render_->font = std::make_unique<Font>(L"Segoe UI",
        static_cast<REAL>(Scale(14)), FontStyleRegular, UnitPixel);
  }
  if (render_->font->GetLastStatus() != Ok) return false;
  HDC screen = GetDC(nullptr);
  if (!screen) return false;
  int detail_width = 0;
  label_width_ = 0;
  height_ = 2 * Scale(kPadding);
  {
    Graphics graphics(screen);
    StringFormat format(StringFormat::GenericTypographic());
    const auto measure = [&](const std::wstring& text) {
      RectF bounds{};
      graphics.MeasureString(text.c_str(), -1, render_->font.get(),
          PointF(0, 0), &format, &bounds);
      return static_cast<int>(std::ceil(bounds.Width));
    };
    for (const auto& row : rows) {
      height_ += Scale(row.separator ? kSeparatorHeight : kRowHeight);
      if (!row.separator) {
        label_width_ = (std::max)(label_width_, measure(row.label));
        if (!row.detail.empty())
          detail_width = (std::max)(detail_width, measure(row.detail));
      }
    }
  }
  ReleaseDC(nullptr, screen);
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
      graphics.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
      StringFormat format(StringFormat::GenericTypographic());
      format.SetLineAlignment(StringAlignmentCenter);
      format.SetFormatFlags(format.GetFormatFlags() | StringFormatFlagsNoWrap);
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
                    Color(pressed_ == hover_ ? 38 : 24, 255, 255, 255));
        const Color foreground(row.enabled ? 255 : 115, 255, 255, 255);
        SolidBrush brush(foreground);
        const REAL icon = static_cast<REAL>(Scale(kIcon));
        const REAL inset = static_cast<REAL>(Scale(kInset));
        DrawIcon(graphics, row, x + inset, y + (h - icon) / 2, icon, foreground);
        const REAL text_x = x + inset + static_cast<REAL>(Scale(kIcon + kGap));
        format.SetAlignment(StringAlignmentNear);
        graphics.DrawString(row.label.c_str(), -1, render_->font.get(),
            RectF(text_x, y, static_cast<REAL>(label_width_ + Scale(2)), h),
            &format, &brush);
        if (!row.detail.empty()) {
          SolidBrush secondary(Color(row.enabled ? 190 : 100, 255, 255, 255));
          const REAL detail_x = text_x + static_cast<REAL>(label_width_ + Scale(kDetailGap));
          format.SetAlignment(StringAlignmentFar);
          graphics.DrawString(row.detail.c_str(), -1, render_->font.get(),
              RectF(detail_x, y, x + w - inset - detail_x, h), &format, &secondary);
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
