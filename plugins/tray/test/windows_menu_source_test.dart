import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

File _resolveSource(String relativePath) {
  final inPlugin = File('plugins/tray/$relativePath');
  if (inPlugin.existsSync()) {
    return inPlugin;
  }
  return File(relativePath);
}

String _body(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: signature);
  final end = source.indexOf('\n}\n', start);
  expect(end, greaterThan(start), reason: signature);
  return source.substring(start, end);
}

void main() {
  late String pluginSource;

  setUpAll(() {
    pluginSource = _resolveSource('windows/tray_plugin.cpp')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
  });

  test('native fallback still uses TrackPopupMenu, not WM_COMMAND', () {
    expect(pluginSource, contains('TPM_RETURNCMD'));
    expect(pluginSource, isNot(contains('WM_COMMAND')));
  });

  test('acrylic menu uses measured labels, tint and no outline', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    expect(source, contains('0x65000000'));
    expect(source, contains('0xfffffffe'));
    expect(source, contains('CreateTextLayout'));
    expect(source, contains('widthIncludingTrailingWhitespace'));
    expect(source, contains('label_width_ + (detail_width ?'));
    expect(source, contains('GetDpiForMonitor'));
    expect(source, contains('VK_ESCAPE'));
    expect(source, contains('WM_CAPTURECHANGED'));
    expect(pluginSource, contains('acrylic_menu_.Open('));
    expect(pluginSource, contains('TPM_RETURNCMD'));
  });

  test('one Direct2D frame uses regular DirectWrite and premultiplied grayscale', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    final cmake = _resolveSource('windows/CMakeLists.txt').readAsStringSync();
    final frame = _body(source, 'bool AcrylicMenu::RenderFrame(');
    expect(source, contains('DWRITE_FONT_WEIGHT_REGULAR'));
    expect(source, isNot(contains('DWRITE_FONT_WEIGHT_MEDIUM')));
    expect(source, contains('Segoe UI Variable Text'));
    expect(frame, contains('D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE'));
    expect(frame, contains('D2D1_ALPHA_MODE_PREMULTIPLIED'));
    expect(frame, contains('GUID_WICPixelFormat32bppPBGRA'));
    expect(frame, contains('DrawTextLayout'));
    expect(frame, contains('DrawGeometry'));
    expect(frame, contains('FillRoundedRectangle'));
    expect(frame, contains('DrawLine'));
    expect(frame, contains('bitmap->CopyPixels'));
    expect(frame.indexOf('target->EndDraw()'), lessThan(frame.indexOf('bitmap->CopyPixels')));
    expect(source, isNot(contains('#include <gdiplus.h>')));
    expect(source, isNot(contains('GdiplusStartup')));
    expect(source, isNot(contains('text_pixels')));
    expect(cmake, isNot(contains('gdiplus')));
    expect(cmake, contains('d2d1 dwrite windowscodecs ole32'));
  });

  test('restart vector shares its clockwise arc endpoint with the arrowhead', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    final start = source.indexOf('} else if (row.icon == "restart")');
    final end = source.indexOf('} else if (row.icon == "exit")', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final glyph = source.substring(start, end);
    expect(glyph, contains('point(13.196f, 5.0f)'));
    expect(glyph, contains('line(13.196f, 5)'));
    expect(glyph, contains('D2D1_SWEEP_DIRECTION_CLOCKWISE'));
    expect(glyph, contains('D2D1_ARC_SIZE_LARGE'));
  });

  test('vector icons snap to physical pixel centers with a common stroke', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    final geometry = _body(source, 'HRESULT CreateIconGeometry(');
    final snap = _body(source, 'float SnapStroke(');
    final frame = _body(source, 'bool AcrylicMenu::RenderFrame(');
    expect(geometry, contains('CreatePathGeometry'));
    expect(geometry, contains('size / 16.0f'));
    expect(geometry, contains('SnapStroke(x + px * scale, stroke)'));
    expect(geometry, contains('SnapStroke(y + py * scale, stroke)'));
    expect(snap, contains('std::round(value - phase) + phase'));
    expect(frame, contains('IconStroke(static_cast<float>(Scale(kIcon)))'));
    expect(frame, contains('SnapStroke(y + h / 2.0f, 1.0f)'));
    expect(source, contains('y + (h - icon) / 2.0f'));
  });

  test('first frame is validated before showing and repaint is cached', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    final open = _body(source, 'bool AcrylicMenu::Open(');
    final frame = _body(source, 'bool AcrylicMenu::RenderFrame(');
    final close = _body(source, 'void AcrylicMenu::Close(');
    expect(open.indexOf('if (!RenderFrame())'), lessThan(open.indexOf('CreateWindowExW')));
    expect(frame, contains('render.painted_hover == hover_'));
    expect(frame, contains('render.painted_pressed == pressed_'));
    expect(close, contains('render_.reset()'));
  });

  test('windows puts the detail in the accelerator column', () {
    expect(pluginSource, contains('StringAt(*entry, "detail")'));
    expect(pluginSource, contains("text += L'\\t';"));
  });

  test('windows show reports a failed icon load', () {
    expect(
      pluginSource,
      contains('''
  if (loaded == nullptr) {
    return false;
  }'''),
    );
  });

  test('windows rejected show leaves the visible menu untouched', () {
    final show = _body(pluginSource, 'bool TrayPlugin::Show(');
    final lastRejection = show.lastIndexOf('return false;');
    final rebuild = show.indexOf('RebuildMenu(menu_, *items);');

    expect(lastRejection, isNonNegative);
    expect(rebuild, greaterThan(lastRejection));
  });

  test('windows retries an icon the shell refused at sign-in', () {
    final show = _body(pluginSource, 'bool TrayPlugin::Show(');

    expect(show, contains('ScheduleRestore();'));
    expect(show.trimRight(), endsWith('return true;'));
    expect(
      _body(pluginSource, 'void TrayPlugin::RestoreIcon('),
      contains('ApplyIcon(false) || ApplyIcon(true)'),
    );
    expect(pluginSource, contains('message == WM_TIMER'));
  });

  test('windows hide deletes an icon whose add may have landed', () {
    final hide = _body(pluginSource, 'void TrayPlugin::Hide(');

    expect(
      hide,
      contains('''
  if (icon_requested_) {
    ::Shell_NotifyIconW(NIM_DELETE, &icon_data_);
  }'''),
    );
    expect(
      hide.indexOf('icon_requested_ = false;'),
      greaterThan(hide.indexOf('NIM_DELETE')),
    );
  });
}
