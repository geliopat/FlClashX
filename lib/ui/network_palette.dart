import 'package:fl_clash/ui/context.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:material_ui/material_ui.dart';

/// Semantic hues independent of accent. The surface estimate is not a
/// measurement of the native DWM backdrop.
enum NetworkTone {
  tcp(0xFFD3A0FF, 0xFF7500B5),
  udp(0xFF62D5FF, 0xFF00617C),
  icmp(0xFFFFB34D, 0xFF934000),
  direct(0xFF82E06A, 0xFF146300),
  reject(0xFFFF7272, 0xFFB00020),
  proxy(0xFF8FA9FF, 0xFF183CB7),
  rule(0xFFF9DC64, 0xFF806000),
  download(0xFF40E1C0, 0xFF005F4D),
  upload(0xFFFF91D2, 0xFFA00068),
  inactive(0xFFAAAAAA, 0xFF515151);

  const NetworkTone(this._dark, this._light);
  final int _dark;
  final int _light;

  static double contrast(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
  }

  Color on(Color background) {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    final darkBackground = contrast(white, background) >= contrast(black, background);
    final base = Color(darkBackground ? _dark : _light);
    if (contrast(base, background) >= 4.5) return base;
    final target = darkBackground ? white : black;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 16; i++) {
      final mid = (lo + hi) / 2;
      if (contrast(Color.lerp(base, target, mid)!, background) >= 4.5) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    final result = Color.lerp(base, target, hi)!;
    return contrast(result, background) >= 4.5 ? result : target;
  }

  static final _cache = <Color, Map<NetworkTone, Color>>{};

  Color of(BuildContext context) {
    final surface = context.surfaceLevel.colorOf(context.colorScheme);
    if (!_cache.containsKey(surface) && _cache.length >= 32) {
      _cache.remove(_cache.keys.first);
    }
    return _cache.putIfAbsent(surface, () => <NetworkTone, Color>{})
        .putIfAbsent(this, () => on(surface));
  }
}
