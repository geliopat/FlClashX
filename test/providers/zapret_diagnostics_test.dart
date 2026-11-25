import 'package:fl_clash/providers/zapret_diagnostics.dart';
import 'package:fl_clash/providers/zapret.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shortlist favors complete reachability then latency, bounded to ten', () {
    const mode = ZapretMode.fullBypass;
    final trials = [
      const ZapretTrial('partial-fast', mode, 4, 40),
      const ZapretTrial('full-slow', mode, 3, 600, confirmed: true),
      const ZapretTrial('full-fast', mode, 6, 100, confirmed: true),
      for (var i = 0; i < 12; i++) ZapretTrial('failed-$i', mode, 0, 0),
    ];
    final selected = shortlistZapretTrials(trials);
    expect(selected, hasLength(10));
    expect(selected.take(3).map((item) => item.id),
        ['full-fast', 'full-slow', 'partial-fast']);
    expect(shortlistZapretTrials(trials, limit: 2).map((item) => item.id),
        ['full-fast', 'full-slow']);
  });

  test('classifies a fast successful probe as operational', () {
    expect(
      classifyZapretProbe(statusCode: 204, latencyMs: 120).status,
      ZapretProbeStatus.operational,
    );
  });

  test('uses the zapret2-gui 450 ms degraded threshold', () {
    expect(
      classifyZapretProbe(statusCode: 200, latencyMs: 451).status,
      ZapretProbeStatus.degraded,
    );
  });

  test('keeps an HTTP error visible as a degraded reachable endpoint', () {
    final result = classifyZapretProbe(statusCode: 403, latencyMs: 80);
    expect(result.status, ZapretProbeStatus.degraded);
    expect(result.httpStatus, 403);
    expect(result.latencyMs, 80);
  });

  test('does not treat an HTTP redirect as a successful probe', () {
    expect(
      classifyZapretProbe(statusCode: 302, latencyMs: 120).status,
      ZapretProbeStatus.degraded,
    );
  });

  test('marks a missing HTTP response as blocked', () {
    expect(
      classifyZapretProbe(statusCode: null, latencyMs: 3500).status,
      ZapretProbeStatus.blocked,
    );
  });
}
