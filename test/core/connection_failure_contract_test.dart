import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy request and native failed request share an IPC contract', () {
    final data = <String, dynamic>{
      'id': 'request-1',
      'start': '2026-11-28T00:00:00Z',
      'metadata': <String, dynamic>{'host': 'example.com', 'network': 'tcp'},
      'chains': ['GROUP'],
      'rule': 'DOMAIN',
      'rulePayload': 'example.com',
    };
    final legacy = TrackerInfo.fromJson(data);
    expect(legacy.failure, isNull);
    expect(legacy.closedAt, isNull);
    final failed = TrackerInfo.fromJson({
      ...data,
      'closedAt': data['start'],
      'failure': {'kind': 'refused', 'message': 'connection refused'},
    });
    expect(failed.failure?.kind, 'refused');
    expect(failed.failure?.message, 'connection refused');
    expect(failed.closedAt, failed.start);
    expect(failed.copyWith(upload: 1).failure, failed.failure);
    expect(failed.copyWith(failure: null).failure, isNull);
    expect(failed.searchFields, contains('connection refused'));
    expect(failed.toJson()['failure'], {'kind': 'refused', 'message': 'connection refused'});
  });
}
