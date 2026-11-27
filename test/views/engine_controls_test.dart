import 'package:fl_clash/views/dashboard/widgets/engine_controls.dart';
import 'package:fl_clash/ui/material_appearance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('uptimes are independent and stopped always shows zero', () {
    expect(engineUptime(false, 9000000), '00:00:00');
    expect(engineUptime(true, 3661000), '01:01:01');
    expect(engineUptime(true, null), '00:00:00');
  });

  testWidgets('buttons occupy exactly 28 percent at the approved centres', (tester) async {
    for (final width in [380.0, 600.0, 1000.0]) {
      await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: width,
        child: const EngineControlsLayout(vpn: SizedBox(), zapret: SizedBox())))));
      final row = tester.getRect(find.byType(EngineControlsLayout));
      final vpn = tester.getRect(find.byKey(const ValueKey('vpn-control-slot')));
      final zapret = tester.getRect(find.byKey(const ValueKey('zapret-control-slot')));
      expect(vpn.width, closeTo(row.width * .28, .001));
      expect(zapret.width, closeTo(vpn.width, .001));
      expect(vpn.height, 53);
      expect(zapret.height, 53);
      expect((vpn.center.dx - row.left) / row.width, closeTo(vpnControlCenterFraction, .001));
      expect((zapret.center.dx - row.left) / row.width, closeTo(zapretControlCenterFraction, .001));
    }
  });
  testWidgets('both stopped and running use material and full clickable area', (tester) async {
    int toggles = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(
      width: 380,
      child: EngineControlsLayout(
        vpn: EngineControlButton(name: 'VPN', actionLabel: 'Start VPN',
          running: false, elapsedMilliseconds: 10000, onPressed: () => toggles++),
        zapret: EngineControlButton(name: 'Zapret', actionLabel: 'Stop Zapret',
          running: true, elapsedMilliseconds: 61000, onPressed: () => toggles++),
      ),
    )))));
    expect(find.text('00:00:00'), findsOneWidget);
    expect(find.text('00:01:01'), findsOneWidget);
    expect(find.byType(LocalMaterialPane), findsNWidgets(2));
    for (final name in ['VPN', 'Zapret']) {
      final rect = tester.getRect(find.byKey(ValueKey('engine-toggle-$name')));
      await tester.tapAt(rect.centerLeft + const Offset(8, 0));
      await tester.pump();
    }
    expect(toggles, 2);
    expect(tester.takeException(), isNull);
  });
}
