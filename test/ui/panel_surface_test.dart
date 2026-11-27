import 'package:fl_clash/ui/surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Windows panel shares page RGB and dims 15% in $brightness', (tester) async {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows, colorScheme: scheme),
        home: Builder(builder: (context) {
          expect(panelScrimOf(context).a, closeTo(.15, .001));
          expect(panelSurfaceOf(scheme), SurfaceLevel.page.colorOf(scheme));
          return const SizedBox.shrink();
        }),
      ));
      expect(tester.takeException(), isNull);
    });
  }
}
