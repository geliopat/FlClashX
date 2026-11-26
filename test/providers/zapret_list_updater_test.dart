import 'package:fl_clash/providers/zapret_list_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Helper LF normalization does not cause repeated writes or failed rollback', () {
    expect(sameZapretList('example.org\r\n', 'example.org\n'), isTrue);
    expect(sameZapretList('example.org\n', '^example.org\n'), isFalse);
    expect(zapretListEntryKey('^Example.org'), isNot(zapretListEntryKey('example.org')));
  });

  test('a clock rollback cannot block retries for hours', () {
    final now = DateTime.utc(2026, 11, 26);
    expect(zapretListsDue(now, null, now.add(const Duration(hours: 3))), isTrue);
  });
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
