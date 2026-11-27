import 'package:fl_clash/ui/hover_glow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('disabled glow and non-hover state produce no shadows', () {
    const color = Color(0xFF123456);
    expect(const HoverGlowTheme(0).shadows(color, hovered: true), isEmpty);
    expect(const HoverGlowTheme(1).shadows(color, hovered: false), isEmpty);
    final full = const HoverGlowTheme(1).shadows(color, hovered: true).single;
    final half = const HoverGlowTheme(.5).shadows(color, hovered: true).single;
    expect(half.blurRadius, full.blurRadius / 2);
    expect(half.color.a, closeTo(full.color.a / 2, .0001));
  });

  test('invalid intensity values cannot escape the supported range', () {
    expect(normalizeGlowIntensity(double.nan), defaultGlowIntensity);
    expect(normalizeGlowIntensity(null), defaultGlowIntensity);
    expect(normalizeGlowIntensity(-1), 0);
    expect(normalizeGlowIntensity(2), 1);
  });
}
