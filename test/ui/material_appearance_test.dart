import 'package:fl_clash/ui/material_appearance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window/window.dart';

void main() {
  test('legacy defaults preserve the original window overlay', () {
    expect(windowOverlayOpacity(WindowEffect.mica, defaultMaterialAppearance), .2);
    expect(windowOverlayOpacity(WindowEffect.acrylic, defaultMaterialAppearance), .32);
    expect(windowOverlayOpacity(WindowEffect.none, defaultMaterialAppearance), 1);
    expect(defaultMaterialAppearance.card, isNull);
  });
  test('separate panes persist independently and invalid input is bounded', () {
    final value = decodeMaterialAppearance({
      'windowOpacity': 0, 'windowTint': 2,
      'card': {'effect': 'micaAlt', 'opacity': .4},
      'button': {'effect': 'acrylic', 'blur': 99, 'tint': -2},
    });
    expect(value.windowOpacity, 0);
    expect(value.windowTint, 1);
    expect(value.card!.effect, WindowEffect.micaAlt);
    expect(value.button!.effect, WindowEffect.acrylic);
    expect(value.button!.blur, 24);
    expect(value.button!.tint, 0);
    expect(decodeMaterialAppearance(encodeMaterialAppearance(value)), value);
  });
  test('opaque stays opaque and acrylic respects local opacity', () {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    final opaque = paneColor(scheme.surface, scheme, defaultPaneAppearance);
    expect(opaque.a, 1);
    final pane = decodePane({'effect': 'acrylic', 'opacity': .4})!;
    expect(paneColor(scheme.surface, scheme, pane).a, closeTo(.4, .0001));
  });
}
