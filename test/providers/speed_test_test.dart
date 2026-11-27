import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/speed_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/views/proxies/common.dart';

void main() {
  test('speed options are transmitted to core without changing route name', () {
    const request = ProxySpeedRequest(proxyName: 'Balance', service: 'cachefly',
      streams: 8, seconds: 15, maxMB: 50, direction: 'download');
    expect(request.toJson()['proxy-name'], 'Balance');
    expect(request.toJson()['streams'], 8);
    expect(request.toJson()['max-mb'], 50);
    expect(request.toJson()['direction'], 'download');
    final result = ProxySpeedResult.fromJson({'download': 15.2, 'download-bytes': 1000000});
    expect(result.downloadBytes, 1000000);
    expect(result.upload, isNull);
  });
  test('legacy Yandex VPN selection migrates to Cloudflare', () {
    expect(vpnSpeedService(SpeedTestService.yandex), SpeedTestService.cloudflare);
    expect(vpnSpeedService(SpeedTestService.custom), SpeedTestService.custom);
  });
  test('dense layout never shows speed measurements', () {
    expect(showProxySpeedMetrics(ProxiesLayout.tight, isWindows: true), isFalse);
    expect(showProxySpeedMetrics(ProxiesLayout.standard, isWindows: true), isTrue);
    expect(showProxySpeedMetrics(ProxiesLayout.loose, isWindows: true), isTrue);
    expect(showProxySpeedMetrics(ProxiesLayout.standard, isWindows: false), isFalse);
  });
  test('global speed target list contains each concrete node once and DIRECT', () {
    const a = Proxy(name: 'A', type: 'Vless');
    const b = Proxy(name: 'B', type: 'Vless');
    const balance = Proxy(name: 'Balance', type: 'LoadBalance');
    const groups = [
      Group(name: 'First', type: GroupType.Selector, all: [a, balance]),
      Group(name: 'Balance', type: GroupType.LoadBalance, all: [a, b]),
      Group(name: 'Second', type: GroupType.Selector, all: [a, b, Proxy(name: 'DIRECT', type: 'Direct')]),
    ];
    expect(speedTestTargets(groups), {'A', 'B', 'DIRECT'});
    expect(speedTestableProxy(balance), isFalse);
  });
  test('custom endpoints require HTTP(S) and no credentials', () {
    expect(validTestEndpoint('https://example.com/up'), isTrue);
    expect(validTestEndpoint('https://a:b@example.com/up'), isFalse);
    expect(validTestEndpoint('file:///tmp/test'), isFalse);
  });
}
