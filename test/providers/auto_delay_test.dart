import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/auto_delay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic ping includes DIRECT, provider nodes and all group types', () {
    const server = Proxy(name: 'node', type: 'Vless', providerName: 'remote');
    const other = Proxy(name: 'other', type: 'Vless');
    const direct = Proxy(name: 'DIRECT', type: 'Direct');
    const groups = [
      Group(name: 'select', type: GroupType.Selector, all: [
        server,
        Proxy(name: 'auto', type: 'URLTest'),
        Proxy(name: 'balance', type: 'LoadBalance'),
        direct,
        Proxy(name: 'REJECT', type: 'Reject'),
        Proxy(name: 'REJECT-DROP', type: 'RejectDrop'),
        Proxy(name: 'PASS', type: 'Pass'),
      ]),
      Group(name: 'auto', type: GroupType.URLTest, now: 'other',
          all: [server, other], testUrl: 'https://example.org/generate_204'),
      Group(name: 'balance', type: GroupType.LoadBalance, all: [server, other],
          testUrl: 'https://example.org/balance'),
      Group(name: 'fallback', type: GroupType.Fallback, all: [direct]),
      Group(name: 'relay', type: GroupType.Relay, all: [server]),
    ];
    final batches = autoDelayBatches(groups.toList());
    expect(batches[0].proxies.map((p) => p.name),
        ['select', 'node', 'auto', 'balance', 'DIRECT']);
    expect(batches[1].proxies.map((p) => p.name), ['auto', 'node', 'other']);
    expect(batches[1].testUrl, 'https://example.org/generate_204');
    expect(batches[2].proxies.map((p) => p.name), ['balance', 'node', 'other']);
    expect(batches[3].proxies.map((p) => p.name), ['fallback', 'DIRECT']);
    expect(batches[4].proxies.map((p) => p.name), ['relay', 'node']);
    expect(batches.last.proxies, [direct]);
    expect(autoDelayBatches([]), isEmpty);

    final targets = <String>{
      for (final batch in batches)
        for (final proxy in batch.proxies)
          delayTestKey(
            computeRealSelectedProxyState(proxy.name, groups: groups, selectedMap: {}).testUrl ??
                batch.testUrl ?? 'https://example.org/default',
            computeRealSelectedProxyState(proxy.name, groups: groups, selectedMap: {}).proxyName,
          ),
    };
    expect(targets, contains(delayTestKey('https://example.org/balance', 'balance')));
    expect(targets, contains(delayTestKey('https://example.org/generate_204', 'other')));
    expect(targets, contains(delayTestKey('https://example.org/default', 'DIRECT')));
    expect(targets, contains(delayTestKey('https://example.org/default', 'fallback')));
    expect(targets, contains(delayTestKey('https://example.org/default', 'relay')));
    expect(isAutoDelayProbeable('DIRECT'), isTrue);
    for (final name in ['REJECT', 'REJECT-DROP', 'PASS']) {
      expect(isAutoDelayProbeable(name), isFalse);
    }
  });

  test('first check is due, zero disables and interval controls repeat', () {
    final now = DateTime.utc(2026, 11, 26);
    expect(autoDelayDue(now: now, last: null, seconds: 0), isFalse);
    expect(autoDelayDue(now: now, last: null, seconds: 15), isTrue);
    final last = now.subtract(const Duration(seconds: 15));
    expect(autoDelayDue(now: now, last: last, seconds: 15), isTrue);
    expect(autoDelayDue(now: now, last: last, seconds: 60), isFalse);
  });
}
