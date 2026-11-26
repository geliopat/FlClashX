import 'package:fl_clash/providers/zapret_infrastructure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts static hosts, proxy and DNS endpoints, and normalized ranges', () {
    final protection = ZapretInfrastructure.fromYaml('''
hosts:
  node.example.org: [192.0.2.10, 2001:db8::10]
  dns.example.org: 192.0.2.53
  panel.example.org: 192.0.2.20
  alias.example.org: node.example.org
tun:
  route-exclude-address:
    - 192.0.2.10/32
    - 10.74.0.0/16
dns:
  fake-ip-range: 198.18.0.1/16
  fake-ip-range6: fd00:198:18::1/64
  direct-nameserver:
    - 'https://dns.example.org/dns-query#Москва'
  proxy-server-nameserver:
    - 'tls://1.1.1.1:853'
  nameserver-policy:
    '+.example.net': 'https://fallback.example.org/dns-query'
  fallback:
    - system
    - 'rcode://success'
proxies:
  - server: node.example.org
  - server: other.example.org
''');
    expect(protection.domains, [
      'alias.example.org',
      'dns.example.org',
      'fallback.example.org',
      'node.example.org',
      'other.example.org',
      'panel.example.org',
    ]);
    expect(protection.ips, [
      '1.1.1.1',
      '10.74.0.0/16',
      '192.0.2.10',
      '192.0.2.10/32',
      '192.0.2.20',
      '192.0.2.53',
      '198.18.0.0/16',
      '2001:db8::10',
      'fd00:198:18::/64',
    ]);
  });

  test('rejects non-map documents and ignores malformed entries', () {
    expect(() => ZapretInfrastructure.fromYaml('- invalid'), throwsFormatException);
    final protection = ZapretInfrastructure.fromYaml('''
hosts:
  'bad/domain': 'invalid value'
tun:
  route-exclude-address:
    - 198.18.0.1/99
    - invalid
''');
    expect(protection.domains, isEmpty);
    expect(protection.ips, isEmpty);
  });
}
