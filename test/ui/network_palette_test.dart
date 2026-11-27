import 'package:fl_clash/ui/network_palette.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('semantic foregrounds meet AA against solid neutral surfaces', () {
    for (var shade = 0; shade < 256; shade++) {
      final background = Color.fromARGB(255, shade, shade, shade);
      for (final tone in NetworkTone.values) {
        expect(NetworkTone.contrast(tone.on(background), background),
            greaterThanOrEqualTo(4.5), reason: '${tone.name} on $shade');
      }
    }
  });
  test('approved palette on dark and white surfaces is stable', () {
    const dark = Color(0xFF222124);
    const light = Color(0xFFFFFFFF);
    expect(NetworkTone.tcp.on(dark), const Color(0xFFD3A0FF));
    expect(NetworkTone.tcp.on(light), const Color(0xFF7500B5));
    expect(NetworkTone.rule.on(dark), const Color(0xFFF9DC64));
    expect(NetworkTone.rule.on(light), const Color(0xFF806000));
  });
}
