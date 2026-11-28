import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/auto_delay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('automatic delay intervals load and persist in preferences', () async {
    SharedPreferences.setMockInitialValues({
      'delay.activeInterval': 10,
      'delay.otherInterval': 120,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(autoDelayProvider), (active: 15, others: 60));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(autoDelayProvider), (active: 10, others: 120));
    await container.read(autoDelayProvider.notifier).set(active: 0, others: 30);
    expect(container.read(autoDelayProvider), (active: 0, others: 30));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('delay.activeInterval'), 0);
    expect(prefs.getInt('delay.otherInterval'), 30);
  });

  test('pending preference load cannot undo an explicit interval change', () async {
    SharedPreferences.setMockInitialValues({
      'delay.activeInterval': 10,
      'delay.otherInterval': 120,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(autoDelayProvider.notifier);
    final first = controller.set(active: 30, others: 60);
    final last = controller.set(active: 0, others: 5);
    await Future.wait([first, last]);
    expect(container.read(autoDelayProvider), (active: 0, others: 5));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('delay.activeInterval'), 0);
    expect(prefs.getInt('delay.otherInterval'), 5);
  });

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

  test('hidden direct and regional balancers are included at their own URLs', () {
    const google = 'https://google.com/generate_204';
    const defaultUrl = 'https://example.org/generate_204';
    const directName = '🔓 Напрямую';
    const ruName = '🇷🇺 Автовыбор';
    const foreignName = '🌍 Автовыбор';
    const groups = [
      Group(name: 'Основной', type: GroupType.Selector, now: ruName, all: [
        Proxy(name: directName, type: 'Selector'),
        Proxy(name: ruName, type: 'LoadBalance'),
        Proxy(name: foreignName, type: 'LoadBalance'),
      ]),
      Group(name: directName, type: GroupType.Selector, hidden: true,
          now: 'DIRECT', all: [Proxy(name: 'DIRECT', type: 'Direct')]),
      Group(name: ruName, type: GroupType.LoadBalance, hidden: true,
          testUrl: google, now: 'Москва', all: [
        Proxy(name: 'Москва', type: 'Vless'),
      ]),
      Group(name: foreignName, type: GroupType.LoadBalance, hidden: true,
          testUrl: google, now: 'Хельсинки', all: [
        Proxy(name: 'Хельсинки', type: 'Vless'),
      ]),
    ];
    final targets = <String>{};
    for (final batch in autoDelayBatches(groups)) {
      for (final proxy in batch.proxies) {
        final resolved = computeRealSelectedProxyState(
          proxy.name, groups: groups, selectedMap: {},
        );
        targets.add(delayTestKey(
          resolved.testUrl ?? batch.testUrl ?? defaultUrl,
          resolved.proxyName,
        ));
      }
    }
    expect(targets, {
      delayTestKey(defaultUrl, 'DIRECT'),
      delayTestKey(google, ruName),
      delayTestKey(google, foreignName),
      delayTestKey(google, 'Москва'),
      delayTestKey(google, 'Хельсинки'),
    });
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
