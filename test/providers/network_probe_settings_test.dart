import 'dart:convert';
import 'package:fl_clash/providers/network_probe_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings round trip preserves custom URL while using a preset', () {
    const settings = NetworkProbeSettings(ipSource: 'IPinfo', customIpUrl: 'https://example.com/ip',
      ipFallback: false, ipTimeout: 15, serviceTimeout: 20);
    final restored = NetworkProbeSettings.decode(jsonEncode(settings.toJson()));
    expect(restored.ipKey, settings.ipKey);
    expect(restored.serviceTimeout, 20);
    expect(restored.copyWith(ipSource: 'custom').selectedIpUrl, 'https://example.com/ip');
  });
  test('invalid saved settings use safe defaults', () {
    final settings = NetworkProbeSettings.decode('{"source":"unknown","customUrl":"file:///tmp/ip","ipTimeout":-1}');
    expect(settings.ipSource, 'auto');
    expect(settings.ipTimeout, 6);
    expect(settings.customIpUrl, const NetworkProbeSettings().customIpUrl);
  });
}
