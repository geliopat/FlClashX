import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/auto_delay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic ping includes provider nodes and computed groups', () {
    const server = Proxy(name: 'node', type: 'Vless', providerName: 'remote');
    const other = Proxy(name: 'other', type: 'Vless');
    const groups = [
      Group(name: 'select', type: GroupType.Selector, all: [
        server,
        Proxy(name: 'auto', type: 'URLTest'),
        Proxy(name: 'DIRECT', type: 'Direct'),
      ]),
      Group(name: 'auto', type: GroupType.URLTest, all: [server, other],
          testUrl: 'https://example.org/generate_204'),
    ];
    final batches = autoDelayBatches(groups.toList());
    expect(batches[0].proxies, [server]);
    expect(batches[1].proxies, [server, other]);
    expect(batches[1].testUrl, 'https://example.org/generate_204');
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
