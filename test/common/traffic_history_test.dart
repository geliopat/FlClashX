import 'package:fl_clash/common/traffic_history.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 11, 26, 12);
  test('independent counters, resets, rolling expiration and restore', () {
    final history = RollingTrafficWindow();
    history.resetBaseline();
    history.record(start, all: const Traffic(up: 100, down: 400),
        proxy: const Traffic(up: 60, down: 200));
    history.record(start.add(const Duration(seconds: 5)),
        all: const Traffic(up: 150, down: 700),
        proxy: const Traffic(up: 80, down: 300));
    expect(history.total(start, onlyProxy: false), const Traffic(up: 150, down: 700));
    expect(history.total(start, onlyProxy: true), const Traffic(up: 80, down: 300));

    history.resetBaseline();
    final later = start.add(const Duration(hours: 1));
    history.record(later, all: const Traffic(up: 20, down: 40));
    final restored = RollingTrafficWindow()..restore(history.toJson(), later);
    expect(restored.total(later, onlyProxy: false), const Traffic(up: 170, down: 740));
    expect(restored.total(start.add(const Duration(hours: 24)), onlyProxy: false),
        const Traffic(up: 20, down: 40));
  });

  test('first sample after reconnect establishes a baseline', () {
    final history = RollingTrafficWindow();
    history.record(start, all: const Traffic(up: 500, down: 900));
    history.record(start, all: const Traffic(up: 510, down: 920));
    expect(history.total(start, onlyProxy: false), const Traffic(up: 10, down: 20));
  });
}
