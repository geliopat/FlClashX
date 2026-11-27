import 'package:fl_clash/views/zapret_logs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy recovery filter includes attempts and failures, not only successes', () {
    for (final message in [
      'Watchdog: engine exited',
      'Restart requested',
      'RECOVERY failed',
    ]) {
      expect(isRecoveryJournalMessage(message), isTrue);
    }
    for (final message in [
      'Engine started',
      'List download complete',
      'HTTP probe failed',
    ]) {
      expect(isRecoveryJournalMessage(message), isFalse);
    }
  });
}
