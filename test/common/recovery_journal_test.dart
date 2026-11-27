import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/file_logger.dart';
import 'package:fl_clash/common/recovery_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structured recovery events round trip and reject corrupt lines', () {
    final event = RecoveryEvent(
      id: 'test', time: DateTime.utc(2026, 11, 27),
      component: 'Mihomo', action: 'watchdog', outcome: RecoveryOutcome.failed,
    );
    final decoded = RecoveryJournal.parseLine('[INFO] RECOVERY_V1 ${jsonEncode(event.toJson())}');
    expect(decoded?.toJson(), event.toJson());
    expect(RecoveryJournal.parseLine('[INFO] RECOVERY_V1 {'), isNull);
    expect(RecoveryJournal.parseLine('unstructured line'), isNull);
  });

  test('journal persists starts and terminal results with shared operation id', () async {
    final folder = await Directory.systemTemp.createTemp('recovery_journal_test');
    final logger = FileLogger(prefix: 'Recovery', directory: () async => folder.path);
    final journal = RecoveryJournal(logger: logger);
    try {
      final id = journal.begin('Helper', 'reinstall');
      journal.record(id, 'Helper', 'reinstall', RecoveryOutcome.succeeded);
      final events = await journal.readRecent();
      expect(events.length, 2);
      expect(events.map((e) => e.id).toSet(), {id});
      expect(events.map((e) => e.outcome).toSet(),
        {RecoveryOutcome.started, RecoveryOutcome.succeeded});
    } finally {
      await logger.dispose();
      await folder.delete(recursive: true);
    }
  });
}
