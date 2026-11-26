import 'dart:convert';

import 'package:fl_clash/providers/smart_hosts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GeoHide falls back to the official RU file after HTTP 503', () async {
    final calls = <String>[];
    final result = await fetchSmartHostSource('geohide', smartHostSourceUrls['geohide']!, (url) async {
      calls.add(url);
      if (calls.length == 1) throw StateError('HTTP 503');
      return '1.2.3.4 example.com';
    });
    expect(calls, [smartHostSourceUrls['geohide'], smartHostFallbackUrls['geohide']!.first]);
    expect(result.fallback, isTrue);
    expect(result.raw, '1.2.3.4 example.com');
  });

  test('MALW uses GitHub contents API if raw endpoint is invalid', () async {
    final result = await fetchSmartHostSource('malw', smartHostSourceUrls['malw']!, (url) async {
      if (url == smartHostSourceUrls['malw']) return '<html>unavailable</html>';
      return jsonEncode({'encoding': 'base64', 'content': base64Encode(utf8.encode('1.2.3.4 example.com'))});
    });
    expect(result.fallback, isTrue);
    expect(result.raw, '1.2.3.4 example.com');
  });

  test('YouTube fallback rejects arbitrary domains', () async {
    await expectLater(fetchSmartHostSource('youtube', smartHostSourceUrls['youtube']!, (_) async => 'youtube.com'), throwsStateError);
  });

  test('failed sources retry independently after fifteen minutes', () {
    final now = DateTime(2026, 11, 26, 12);
    final success = now.subtract(const Duration(hours: 1));
    bool due(DateTime? failure) => smartHostUpdateDue(
      now: now, interval: const Duration(hours: 24),
      lastSuccess: success, lastFailure: failure,
    );
    expect(due(null), isFalse);
    expect(due(now.subtract(const Duration(minutes: 14))), isFalse);
    expect(due(now.subtract(const Duration(minutes: 15))), isTrue);
    expect(smartHostUpdateDue(now: now, interval: const Duration(hours: 24), lastSuccess: null, lastFailure: null), isTrue);
  });

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
