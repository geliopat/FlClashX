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

  test('acrylic text uses medium DirectWrite and premultiplied grayscale', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    final cmake = _resolveSource('windows/CMakeLists.txt').readAsStringSync();
    expect(source, contains('DWRITE_FONT_WEIGHT_MEDIUM'));
    expect(source, contains('Segoe UI Variable Text'));
    expect(source, contains('D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE'));
    expect(source, contains('D2D1_ALPHA_MODE_PREMULTIPLIED'));
    expect(source, contains('GUID_WICPixelFormat32bppPBGRA'));
    expect(source, contains('DrawTextLayout'));
    expect(source, contains('text_bitmap->CopyPixels'));
    expect(source, isNot(contains('graphics.DrawString')));
    expect(cmake, contains('d2d1 dwrite windowscodecs ole32'));
  });

  test('restart glyph joins its clockwise arc to the arrowhead', () {
    final source = _resolveSource('windows/acrylic_menu.cpp').readAsStringSync();
    final start = source.indexOf('row.icon == "restart"');
    final end = source.indexOf('row.icon == "exit"', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final glyph = source.substring(start, end);
    expect(glyph, contains('15.0f, 315.0f'));
    expect(glyph, contains('{13.2f, 5.0f}'));
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
