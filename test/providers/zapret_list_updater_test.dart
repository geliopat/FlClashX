import 'package:fl_clash/providers/zapret_list_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first launch is due and success schedules the next check in 12 hours', () {
    final start = DateTime.utc(2026, 11, 26);
    expect(zapretListsDue(start, null, null), isTrue);
    expect(zapretListsDue(start.add(const Duration(hours: 11)), start, null), isFalse);
    expect(zapretListsDue(start.add(const Duration(hours: 12)), start, null), isTrue);
  });

  test('a failure backs off for five minutes and then retries', () {
    final start = DateTime.utc(2026, 11, 26);
    final retry = start.add(zapretListRetryInterval);
    expect(zapretListsDue(start, null, retry), isFalse);
    expect(zapretListsDue(retry, null, retry), isTrue);
  });
}
