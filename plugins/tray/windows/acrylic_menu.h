#pragma once

#include <windows.h>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace tray {

struct AcrylicRow {
  int id = 0;
  bool separator = false;
  bool enabled = true;
  bool checked = false;
  std::wstring label;
  std::wstring detail;
  std::string icon;
};

class AcrylicMenu {
 public:
  AcrylicMenu();
  ~AcrylicMenu();
  bool Open(HWND owner, POINT anchor, const std::vector<AcrylicRow>& rows,
            std::function<void(int)> selected);
  void Close();

 private:
  struct Render;
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp,
                                    LPARAM lp);
  LRESULT Handle(HWND window, UINT message, WPARAM wp, LPARAM lp);
  void Paint(HWND window);
  void Select(int index);
  void MoveSelection(int direction);
  int Hit(POINT point) const;
  int Scale(int dip) const;

  HWND window_ = nullptr;
  UINT dpi_ = 96;
  int width_ = 0;
  int height_ = 0;
  int label_width_ = 0;
  int hover_ = -1;
  int pressed_ = -1;
  std::vector<AcrylicRow> rows_;
  std::vector<RECT> bounds_;
  std::function<void(int)> selected_;
  std::unique_ptr<Render> render_;
};

}  // namespace tray
