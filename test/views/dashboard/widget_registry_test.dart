import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const status = DashboardWidget.currentOutbound;
  const announcement = DashboardWidget.announcement;
  const speed = DashboardWidget.networkSpeed;
  const profiles = DashboardWidget.profiles;

  test('keeps the saved places of the status card and the announcement', () {
    expect(
      withFixedCards(const [
        speed,
        status,
        profiles,
        announcement,
      ], announcement: true),
      const [speed, status, profiles, announcement],
    );
  });

  test('puts an unplaced status card and announcement on top', () {
    expect(withFixedCards(const [speed, profiles], announcement: true), const [
      announcement,
      status,
      speed,
      profiles,
    ]);
  });

  test('keeps Windows Zapret widgets in older saved layouts', () {
    final result = withFixedCards(
      const [speed, profiles],
      announcement: false,
      platform: SupportPlatform.Windows,
    );
    expect(result, contains(DashboardWidget.vpnButton));
    expect(result, contains(DashboardWidget.zapretDiagnostics));
    expect(
      DashboardWidget.vpnButton.removable(
        providerMode: false,
        platform: SupportPlatform.Windows,
      ),
      isFalse,
    );
    expect(
      DashboardWidget.zapretDiagnostics.removable(
        providerMode: false,
        platform: SupportPlatform.Windows,
      ),
      isFalse,
    );
  });

  test('leaves the announcement out while the subscription sends none', () {
    expect(
      withFixedCards(const [speed, announcement, status], announcement: false),
      const [speed, status],
    );
  });
}
