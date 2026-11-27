import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('source snapshot keeps false, zero, empty, nested and policy suffixes', () {
    final raw = <String, dynamic>{
      'dns': {'respect-rules': false, 'ipv6-timeout': 0, 'fallback': [],
        'nameserver-policy': {'example.org': ['https://dns.example/dns-query#Auto']},
        'fallback-filter': {'geoip': false, 'domain': []}, 'future-option': true},
      'tun': {'strict-route': false, 'route-exclude-address': []},
      'sniffer': {'sniff': {'http': {'ports': [80], 'override-destination': false}}},
    };
    final sources = yamlSectionSourcesOf(42, raw);
    expect(sources.profileId, 42);
    expect(sources.dns['respect-rules'], false);
    expect(sources.dns['ipv6-timeout'], 0);
    expect(sources.dns['fallback'], []);
    expect(sources.dns['fallback-filter.geoip'], false);
    expect(sources.dns['nameserver-policy'], {'example.org': ['https://dns.example/dns-query#Auto']});
    expect(sources.dns.containsKey('future-option'), false);
    expect(raw['dns']['future-option'], true);
    expect(sources.tun['strict-route'], false);
    expect(sources.sniffer['sniff.HTTP'], {'ports': [80], 'override-destination': false});
    expect(overrideFieldDocument(DnsOverrideKey.fallbackFilterGeoip, false),
      {'fallback-filter': {'geoip': false}});
  });
  test('explicit empty TUN and sniffer overrides may clear inherited lists', () {
    expect(defaultProfileTun.overrideJson({TunOverrideKey.routeExcludeAddress}, keepEmpty: true),
      {'route-exclude-address': []});
    expect(defaultSniffer.overrideJson({SnifferOverrideKey.skipDomain}, keepEmpty: true),
      {'skip-domain': []});
  });
}
