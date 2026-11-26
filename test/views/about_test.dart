import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/flclashz_upstream_versions.dart';
import 'package:fl_clash/providers/zapret_components.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/about.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_app.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

void main() {
  late ProviderContainer container;
  late _MockCore core;

  setUp(() {
    core = _MockCore();
    when(() => core.getCoreVersion()).thenAnswer((_) async => 'v1.19.32');
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
      ],
    );
    globalState.container = container;
    globalState.packageInfo = PackageInfo(
      appName: appName,
      packageName: packageName,
      version: '1.2.3',
      buildNumber: '7',
    );
    addTearDown(container.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(locale: Locale('en'), child: AboutView()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('shows the app and core versions as badges', (tester) async {
    await pump(tester);

    expect(find.text('FlClashZ v1.2.3'), findsOneWidget);
    expect(find.text('Mihomo: v1.19.32'), findsOneWidget);
    expect(find.text('GPL-3.0'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('version badges have the expected repository links', (tester) async {
    await pump(tester);

    final links = <String, String>{
      'FlClashZ v1.2.3': 'https://github.com/geliopat/FlClashZ',
      'FlClashX v$flClashXVersion': 'https://github.com/pluralplay/FlClashX',
      'Mihomo: v1.19.32': 'https://github.com/MetaCubeX/mihomo',
      'GPL-3.0': 'https://www.gnu.org/licenses/gpl-3.0.html',
      'Zapret2: ${installedZapretComponents['Zapret2']}':
          'https://github.com/bol-van/zapret2',
      'Flowseal: ${installedZapretComponents['Flowseal']}':
          'https://github.com/Flowseal/zapret-discord-youtube',
      'Стратегии Lua/BAT: ${installedZapretComponents['Стратегии Lua/BAT']}':
          'https://github.com/geliopat/zapret2-gui',
    };
    for (final entry in links.entries) {
      final badge = find.text(entry.key);
      expect(badge, findsOneWidget);
      final tooltip = find.ancestor(of: badge, matching: find.byType(Tooltip));
      expect(tooltip, findsOneWidget);
      expect(tester.widget<Tooltip>(tooltip).message, entry.value);
      final ink = find.descendant(of: tooltip, matching: find.byType(InkWell));
      expect(ink, findsOneWidget);
      expect(tester.widget<InkWell>(ink).onTap, isNotNull);
    }
  });

  testWidgets('lists the links and the people behind the fork', (tester) async {
    await pump(tester);

    expect(find.text('Original repository'), findsOneWidget);
    expect(find.text('github.com/chen08209/FlClash'), findsOneWidget);
    expect(find.text('github.com/MetaCubeX/mihomo'), findsOneWidget);
    expect(find.text('github.com/pluralplay/FlClashX'), findsOneWidget);
    expect(find.text('Fork author'), findsOneWidget);
    expect(find.text('pluralplay'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNWidgets(2));
    expect(find.text('x_kit_'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a core that does not answer uses the bundled version', (
    tester,
  ) async {
    when(() => core.getCoreVersion()).thenThrow(StateError('not running'));
    await pump(tester);

    expect(find.text('FlClashZ v1.2.3'), findsOneWidget);
    expect(find.text('Mihomo: ${coreVersionDefine.isNotEmpty ? coreVersionDefine : bundledMihomoVersion}'), findsOneWidget);
  });
}
