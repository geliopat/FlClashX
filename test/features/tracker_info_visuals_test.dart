import 'package:fl_clash/ui/network_palette.dart';
import 'package:fl_clash/ui/flag.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

TrackerInfo _tracker({
  String host = 'example.com',
  List<String> geoIp = const [],
  String process = '',
}) => TrackerInfo(
  id: '1',
  start: DateTime(2026, 1, 1),
  metadata: Metadata(
    network: 'tcp',
    host: host,
    process: process,
    destinationGeoIP: geoIp,
  ),
  chains: const [],
  rule: 'MATCH',
  rulePayload: '',
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    TestApp(
      homeBuilder: (child) => Scaffold(body: Center(child: child)),
      child: child,
    ),
  );
  await tester.pump();
}


void main() {
  testWidgets('the avatar shows the destination flag, else the host letter', (
    tester,
  ) async {
    await _pump(tester, TrackerAvatar(trackerInfo: _tracker(geoIp: ['US'])));
    expect(find.byType(CountryFlag), findsOneWidget);
    expect(find.text('E'), findsNothing);

    await _pump(tester, TrackerAvatar(trackerInfo: _tracker(geoIp: ['ZZ'])));
    expect(find.byType(CountryFlag), findsNothing);
    expect(find.text('E'), findsOneWidget);

    await _pump(tester, TrackerAvatar(trackerInfo: _tracker(host: '')));
    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('outbound text uses semantic colours without chips', (
    tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: [
          OutboundChip(label: 'DIRECT'),
          OutboundChip(label: 'REJECT'),
          OutboundChip(label: 'HK 01'),
          OutboundChip(label: 'Auto', exit: false),
        ],
      ),
    );
    final context = tester.element(find.text('DIRECT'));
    Color? color(String label) => tester.widget<Text>(find.text(label)).style?.color;
    expect(color('DIRECT'), NetworkTone.direct.of(context));
    expect(color('REJECT'), NetworkTone.reject.of(context));
    expect(color('HK 01'), NetworkTone.proxy.of(context));
    expect(color('Auto'), NetworkTone.inactive.of(context));
  });

  testWidgets('speeds are coloured only while traffic flows', (tester) async {
    await _pump(tester, const SpeedText(upload: 0, download: 4096));
    final rich = tester.widget<Text>(find.byType(Text).first).textSpan!;
    final colors = <Color?>[];
    rich.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').contains('/s')) {
        colors.add(span.style?.color);
      }
      return true;
    });
    final context = tester.element(find.byType(Text).first);
    expect(colors, [NetworkTone.inactive.of(context), NetworkTone.download.of(context)]);
  });
}
