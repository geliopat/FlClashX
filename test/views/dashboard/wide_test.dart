import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/wide.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<DashboardWidget>> _rows(List<DashboardWidget> cards, int columns) => [
  for (final row in wideRowsOf(cards, columns)) row.cards,
];

void main() {
  test('the full arrangement lays out the grid it always had', () {
    final cards = [
      DashboardWidget.announcement,
      ...wideDashboardWidgetsOf(SupportPlatform.MacOS),
    ];

    expect(_rows(cards, 4), [
      [DashboardWidget.announcement],
      [DashboardWidget.currentOutbound, DashboardWidget.networkSpeed],
      [DashboardWidget.outboundMode, DashboardWidget.networkTakeover],
      [
        DashboardWidget.intranetIp,
        DashboardWidget.profiles,
        DashboardWidget.serviceStatus,
        DashboardWidget.memoryInfo,
      ],
      [DashboardWidget.connectionStats, DashboardWidget.proxyGroups],
    ]);
    expect(_rows(cards, 2), [
      [DashboardWidget.announcement],
      [DashboardWidget.currentOutbound],
      [DashboardWidget.networkSpeed],
      [DashboardWidget.outboundMode],
      [DashboardWidget.networkTakeover],
      [DashboardWidget.intranetIp, DashboardWidget.profiles],
      [DashboardWidget.serviceStatus, DashboardWidget.memoryInfo],
      [DashboardWidget.connectionStats, DashboardWidget.proxyGroups],
    ]);
  });

  test('the arrangement holds the switches each platform has', () {
    expect(
      wideDashboardWidgetsOf(SupportPlatform.Android),
      contains(DashboardWidget.vpnButton),
    );
    expect(
      wideDashboardWidgetsOf(SupportPlatform.Android),
      isNot(contains(DashboardWidget.networkTakeover)),
    );
    expect(
      wideDashboardWidgetsOf(SupportPlatform.Windows),
      isNot(contains(DashboardWidget.vpnButton)),
    );
    expect(
      wideDashboardWidgetsOf(SupportPlatform.Windows),
      contains(DashboardWidget.zapret),
    );
    expect(
      _rows(wideDashboardWidgetsOf(SupportPlatform.Windows), 4),
      contains(equals([DashboardWidget.zapret])),
    );
  });

  test('Zapret strategy row has space at all supported text scales', () {
    const zapret = WideRow(WideRowKind.control, [DashboardWidget.zapret]);
    const ordinary = WideRow(WideRowKind.control, [DashboardWidget.outboundMode]);
    for (final scale in [1.0, 1.25, 1.5, 2.0]) {
      for (final compact in [true, false]) {
        expect(wideControlRowHeight(zapret, compact: compact, scale: scale), 128 * scale);
        expect(wideControlRowHeight(ordinary, compact: compact, scale: scale),
            (compact ? 56 : 64) * scale);
      }
    }
  });

  test('a card starts a new row when its kind changes or the row is full', () {
    expect(
      _rows(const [
        DashboardWidget.memoryInfo,
        DashboardWidget.currentOutbound,
        DashboardWidget.profiles,
        DashboardWidget.intranetIp,
        DashboardWidget.serviceStatus,
        DashboardWidget.memoryInfo,
        DashboardWidget.intranetIp,
      ], 4),
      [
        [DashboardWidget.memoryInfo],
        [DashboardWidget.currentOutbound],
        [
          DashboardWidget.profiles,
          DashboardWidget.intranetIp,
          DashboardWidget.serviceStatus,
          DashboardWidget.memoryInfo,
        ],
        [DashboardWidget.intranetIp],
      ],
    );
  });
}
