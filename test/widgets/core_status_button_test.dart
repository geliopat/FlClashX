import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/window_manager.dart';
import 'package:fl_clash/views/dashboard/widgets/zapret_status_button.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/dashboard/widgets/core_status_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/glyph_finders.dart';
import '../helpers/test_app.dart';

CoreStatus _shown(WidgetTester tester) =>
    tester.widget<CorePulse>(find.byType(CorePulse)).status;

class _IdleZapret extends ZapretController {
  @override
  ZapretState build() => const ZapretState();
}

ProviderContainer _container() => ProviderContainer(
  overrides: [zapretControllerProvider.overrideWith(_IdleZapret.new)],
);

void main() {
  testWidgets('window uses the original single combined restart control', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(1200, 800);
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const TestApp(includeNavigatorKey: false, child: Scaffold(
        body: Center(child: WindowEngineActions()),
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(CoreStatusButton), findsOneWidget);
    expect(find.byType(ZapretStatusButton), findsNothing);
    expect(find.byType(CorePulse), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byTooltip(Platform.isWindows ? 'Restart all' : 'Core status'), findsOneWidget);
  });
  testWidgets(
    'holds connecting for the minimum duration after a fast restart',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      globalState.container = container;
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            includeNavigatorKey: false,
            homeBuilder: (child) => Scaffold(body: Center(child: child)),
            child: const CoreStatusButton(),
          ),
        ),
      );
      await tester.pump();

      expect(_shown(tester), CoreStatus.connected);

      container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_shown(tester), CoreStatus.connecting);

      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await tester.pump();
      expect(_shown(tester), CoreStatus.connecting);

      await tester.pump(const Duration(milliseconds: 199));
      expect(_shown(tester), CoreStatus.connecting);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_shown(tester), CoreStatus.connected);

      await tester.pump(const Duration(seconds: 1));
      expect(_shown(tester), CoreStatus.connected);
    },
  );

  testWidgets(
    'shows disconnected immediately when restart fails during the hold',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      globalState.container = container;
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            includeNavigatorKey: false,
            homeBuilder: (child) => Scaffold(body: Center(child: child)),
            child: const CoreStatusButton(),
          ),
        ),
      );
      await tester.pump();

      container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_shown(tester), CoreStatus.connecting);

      container.read(coreStatusProvider.notifier).value =
          CoreStatus.disconnected;
      await tester.pump();
      expect(_shown(tester), CoreStatus.disconnected);

      await tester.pump(const Duration(milliseconds: 400));
      expect(_shown(tester), CoreStatus.disconnected);

      await tester.pump(const Duration(seconds: 1));
      expect(_shown(tester), CoreStatus.disconnected);
    },
  );

  testWidgets('labels the status on desktop and keeps it an icon on mobile', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    globalState.container = container;
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;

    Future<void> pumpAt(Size size) async {
      container.read(viewSizeProvider.notifier).value = size;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            includeNavigatorKey: false,
            homeBuilder: (child) => Scaffold(body: Center(child: child)),
            child: const CoreStatusButton(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    await pumpAt(const Size(1200, 800));
    expect(find.text('Disconnected'), findsOneWidget);
    expect(_shown(tester), CoreStatus.disconnected);

    await pumpAt(const Size(400, 800));
    expect(find.text('Disconnected'), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
    expect(_shown(tester), CoreStatus.disconnected);
    expect(find.byTooltip(Platform.isWindows ? 'Restart all' : 'Core status'), findsOneWidget);

    container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Connecting…'), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
    expect(_shown(tester), CoreStatus.connecting);
  });

  testWidgets('does not clip a connecting state longer than the hold', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    globalState.container = container;
    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          includeNavigatorKey: false,
          homeBuilder: (child) => Scaffold(body: Center(child: child)),
          child: const CoreStatusButton(),
        ),
      ),
    );
    await tester.pump();

    container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_shown(tester), CoreStatus.connecting);

    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_shown(tester), CoreStatus.connected);

    await tester.pump(const Duration(seconds: 1));
    expect(_shown(tester), CoreStatus.connected);
  });

  testWidgets('holds connecting when restarting from disconnected', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    globalState.container = container;
    container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          includeNavigatorKey: false,
          homeBuilder: (child) => Scaffold(body: Center(child: child)),
          child: const CoreStatusButton(),
        ),
      ),
    );
    await tester.pump();

    expect(_shown(tester), CoreStatus.disconnected);

    container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_shown(tester), CoreStatus.connecting);
    expect(find.byGlyph(AppGlyphs.refresh), findsNothing);

    container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    await tester.pump();
    expect(_shown(tester), CoreStatus.connecting);

    await tester.pump(const Duration(milliseconds: 199));
    expect(_shown(tester), CoreStatus.connecting);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_shown(tester), CoreStatus.connected);

    await tester.pump(const Duration(seconds: 1));
    expect(_shown(tester), CoreStatus.connected);
  });
}
