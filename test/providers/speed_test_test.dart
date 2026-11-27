import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/speed_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
