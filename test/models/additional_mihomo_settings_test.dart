import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('additional overrides replace only explicit paths, preserve zero/false/empty', () {
    final raw = <String,dynamic>{
      'geodata-mode': true, 'tun': {'auto-route': true, 'icmp-timeout': 20, 'loopback-address': ['127.0.0.1']},
      'profile': {'store-selected': false, 'store-fake-ip': true},
    };
    applyAdditionalSettings(raw, 'geodata-mode: false\ntun.icmp-timeout: 0\ntun.loopback-address: []\nprofile.store-fake-ip: false');
    expect(raw['geodata-mode'], false);
    expect(raw['tun'], {'auto-route': true, 'icmp-timeout': 0, 'loopback-address': []});
    expect(raw['profile'], {'store-selected': false, 'store-fake-ip': false});
  });
  test('app owned and arbitrary paths are refused', () {
    for (final path in ['tun.auto-route', 'tun.file-descriptor', 'external-controller-pipe', 'authentication', 'listeners', 'proxy-providers']) {
      expect(() => decodeAdditionalSettings('$path: false'), throwsFormatException);
    }
    expect(() => decodeAdditionalSettings('tun.icmp-timeout: -1'), throwsFormatException);
  });
  test('profile persistence and release are independent', () {
    const initial = ProfileOverrides(additionalSettingsYaml: 'geodata-mode: false');
    final restored = ProfileOverrides.fromJson(initial.toJson());
    expect(restored.additionalSettingsYaml, initial.additionalSettingsYaml);
    expect(restored.copyWith(additionalSettingsYaml: '').additionalSettingsYaml, '');
    expect(restored.copyWith(), restored);
  });
}
