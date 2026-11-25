import 'package:fl_clash/providers/smart_hosts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual and profile entries retain priority and wildcard protection', () {
    final config = <String, dynamic>{
      'hosts': {'my.example': ['1.2.3.4'], '+.protected.example': '5.6.7.8'},
      'dns': {'enable': true, 'nameserver': ['https://dns.example/dns-query']},
    };
    final result = mergeSmartHosts(config, {'manual.example': '1.1.1.1'}, {
      'my.example': '9.9.9.9',
      'manual.example': '9.9.9.9',
      'sub.protected.example': '9.9.9.9',
      'new.example': '8.8.8.8',
    });
    expect(result['hosts'], {
      'my.example': ['1.2.3.4'],
      '+.protected.example': '5.6.7.8',
      'new.example': '8.8.8.8',
    });
    expect(config['hosts'], hasLength(2));
    expect(result['dns'], same(config['dns']));
  });

  test('parser rejects malformed, loopback and localhost by default', () {
    expect(parseSmartHosts('1.2.3.4 Example.COM other.example # comment\n127.0.0.1 ads.example\n1.1.1.1 localhost\nnot-ip bad.example'), {
      'example.com': '1.2.3.4',
      'other.example': '1.2.3.4',
    });
    expect(parseSmartHosts('0.0.0.0 ads.example', includeAdblock: true), {'ads.example': '0.0.0.0'});
  });

  test('YouTube list cannot block arbitrary domains', () {
    expect(parseYoutubeNodes('rr1---sn-test.googlevideo.com\nwww.youtube.com\nrr1---sn-test.googlevideo.com.evil.example'), {
      'rr1---sn-test.googlevideo.com': '127.0.0.2',
    });
  });
}
