import 'dart:async';

import 'package:fl_clash/core/connection_snapshot.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo connection(String id, String network) => TrackerInfo(
  id: id,
  start: DateTime(2026),
  metadata: Metadata(network: network),
  chains: const [],
  rule: 'MATCH',
  rulePayload: '',
);

void main() {
  test('coalesces reads, counts protocols, reuses unchanged snapshots', () async {
    var elapsed = Duration.zero;
    var reads = 0;
    final items = [connection('a', 'TCP'), connection('b', 'udp')];
    final reader = ConnectionSnapshotReader(() async {
      reads++;
      return List.of(items);
    }, elapsed: () => elapsed);
    final a = reader.read();
    final b = reader.read();
    expect(a, same(b));
    final first = await a;
    expect(first.count, 2);
    expect(first.tcp, 1);
    expect(first.udp, 1);
    expect(await reader.read(), same(first));
    expect(reads, 1);
    elapsed += const Duration(seconds: 1);
    expect(await reader.read(), same(first));
    expect(reads, 2);
    items.clear();
    reader.invalidate();
    expect((await reader.read()).count, 0);
  });

  test('invalidated in-flight sample cannot enter a new session', () async {
    final pending = Completer<List<TrackerInfo>>();
    var reads = 0;
    final reader = ConnectionSnapshotReader(() {
      reads++;
      return reads == 1 ? pending.future : Future.value([]);
    });
    final old = reader.read();
    final rejected = expectLater(old, throwsStateError);
    reader.invalidate();
    expect((await reader.read()).count, 0);
    pending.complete([connection('old', 'tcp')]);
    await rejected;
    expect((await reader.read()).count, 0);
  });
}
