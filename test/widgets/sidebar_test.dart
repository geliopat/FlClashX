import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/sidebar.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

final _paneFinder = find.byKey(const ValueKey('sidebar-overlay-surface'));

const _destinations = [
  SidebarDestination(glyph: AppGlyphs.dashboard, label: 'Dashboard'),
  SidebarDestination(glyph: AppGlyphs.proxies, label: 'Proxies'),
  SidebarDestination(glyph: AppGlyphs.profiles, label: 'Profiles'),
];

Finder _glyph(Glyph glyph) => find.byWidgetPredicate(
  (widget) => widget is AnimatedGlyph && widget.glyph == glyph,
);

double _fillOf(WidgetTester tester, Glyph glyph) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(of: _glyph(glyph), matching: find.byType(CustomPaint)),
  );
  return (paint.painter! as GlyphPainter).fill;
}

Widget _sidebar({
  List<SidebarDestination> destinations = _destinations,
  int selectedIndex = 0,
  bool expanded = true,
  ValueChanged<int>? onSelected,
  VoidCallback? onToggle,
  Size windowControls = Size.zero,
  bool pinLastDestination = false,
  Widget? footer,
  Set<int> footerDestinations = const {},
  double height = 400,
  ThemeData? theme,
  EdgeInsets safePadding = EdgeInsets.zero,
}) {
  return TestApp(
    theme: theme ?? ThemeData(platform: TargetPlatform.android),
    child: Scaffold(
      body: Row(
        children: [
          SizedBox(
            height: height,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(padding: safePadding),
                child: NavigationSidebar(
                  destinations: destinations,
                  selectedIndex: selectedIndex,
                  expanded: expanded,
                  onSelected: onSelected ?? (_) {},
                  onToggle: onToggle,
                  windowControls: windowControls,
                  pinLastDestination: pinLastDestination,
                  footer: footer,
                  footerDestinations: footerDestinations,
                ),
              ),
            ),
          ),
          const Expanded(child: SizedBox.expand(key: ValueKey('content'))),
        ],
      ),
    ),
  );
}

Finder get _sidebarFinder => find.byType(NavigationSidebar);

Finder _indicator(WidgetTester tester) {
  final primary = Theme.of(tester.element(_sidebarFinder)).colorScheme.primary;
  return find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is ShapeDecoration &&
        (widget.decoration as ShapeDecoration).color == primary,
  );
}

Finder _labels(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate(
    (widget) => widget is Opacity && widget.alwaysIncludeSemantics,
  ),
);

Iterable<double> _labelOpacities(WidgetTester tester, String label) {
  return tester.widgetList<Opacity>(_labels(label)).map((o) => o.opacity);
}

Finder _shown(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) =>
        widget is Opacity &&
        widget.alwaysIncludeSemantics &&
        widget.opacity == 1,
  ),
  matching: find.text(label),
);

Finder _rowTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && widget.message == message,
);

void main() {
  testWidgets('expanded statistics replace the duplicate destination but compact keeps it', (tester) async {
    await tester.pumpWidget(_sidebar(height: 550, footer: const Text('Traffic'), footerDestinations: {1}));
    await tester.pumpAndSettle();
    expect(find.text(_destinations[1].label), findsNothing);
    await tester.pumpWidget(_sidebar(height: 550, expanded: false, footer: const Text('Traffic'), footerDestinations: {1}));
    await tester.pumpAndSettle();
    expect(_glyph(_destinations[1].glyph), findsOneWidget);
  });
  testWidgets('statistics sidebar fits labels instead of a fixed width', (tester) async {
    await tester.pumpWidget(_sidebar(
      footer: const Text('Traffic'),
      pinLastDestination: true,
    ));
    final shortWidth = tester.getSize(_sidebarFinder).width;
    expect(shortWidth, inInclusiveRange(164.0, 219.0));
    expect(_rowTooltip('Dashboard'), findsNothing);
    await tester.pumpWidget(_sidebar(
      destinations: const [
        ..._destinations,
        SidebarDestination(glyph: AppGlyphs.settings, label: 'Long translated settings label'),
      ],
      footer: const Text('Traffic'),
      pinLastDestination: true,
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(_sidebarFinder).width, greaterThan(shortWidth));
    expect(tester.getSize(_sidebarFinder).width, lessThanOrEqualTo(260.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned settings stay below the sidebar footer', (tester) async {
    int? selected;
    await tester.pumpWidget(_sidebar(
      destinations: const [..._destinations,
        SidebarDestination(glyph: AppGlyphs.settings, label: 'Settings')],
      pinLastDestination: true,
      footer: const Text('Traffic'),
      onSelected: (index) => selected = index,
    ));
    expect(tester.getBottomLeft(find.text('Traffic')).dy,
        lessThan(tester.getTopLeft(find.text('Settings')).dy));
    await tester.tap(find.text('Settings'));
    expect(selected, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection changes only text and glyph accent', (tester) async {
    await tester.pumpWidget(_sidebar(selectedIndex: 1));
    final scheme = Theme.of(tester.element(_sidebarFinder)).colorScheme;
    expect(_indicator(tester), findsNothing);
    expect(tester.widget<Text>(find.text('Proxies')).style?.color, scheme.primary);
    expect(tester.widget<Text>(find.text('Dashboard')).style?.color, scheme.onSurface);
    final glyph = tester.widget<CustomPaint>(
      find.descendant(of: _glyph(AppGlyphs.proxies), matching: find.byType(CustomPaint)),
    ).painter! as GlyphPainter;
    expect(glyph.color, scheme.primary);
    final material = tester.widget<Material>(find.ancestor(
      of: _glyph(AppGlyphs.proxies), matching: find.byType(Material),
    ).first);
    expect(material.color, Colors.transparent);
    expect(tester.getSemantics(find.text('Proxies')),
        isSemantics(isSelected: true, isButton: true));

    await tester.pumpWidget(_sidebar(selectedIndex: 2));
    await tester.pumpAndSettle();
    expect(_indicator(tester), findsNothing);
    expect(tester.widget<Text>(find.text('Profiles')).style?.color, scheme.primary);
  });

  testWidgets('glyph glow appears only while hovering a row', (tester) async {
    await tester.pumpWidget(_sidebar());
    GlyphPainter painter() => tester.widget<CustomPaint>(
      find.descendant(of: _glyph(AppGlyphs.proxies), matching: find.byType(CustomPaint)),
    ).painter! as GlyphPainter;
    expect(painter().shadows, isEmpty);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(_glyph(AppGlyphs.proxies)));
    await tester.pump();
    expect(painter().shadows, isNotEmpty);
    await mouse.moveTo(const Offset(600, 300));
    await tester.pump();
    expect(painter().shadows, isEmpty);
  });

  testWidgets('only the selected row fills its icon', (tester) async {
    await tester.pumpWidget(_sidebar());
    expect(_fillOf(tester, AppGlyphs.dashboard), 1);
    expect(_fillOf(tester, AppGlyphs.profiles), 0);

    await tester.pumpWidget(_sidebar(selectedIndex: 2));
    await tester.pumpAndSettle();
    expect(_fillOf(tester, AppGlyphs.dashboard), 0);
    expect(_fillOf(tester, AppGlyphs.profiles), 1);
  });

  testWidgets('the toggle widens the sidebar in place when it can', (
    tester,
  ) async {
    var toggled = 0;
    int? selected;
    await tester.pumpWidget(
      _sidebar(
        expanded: false,
        onToggle: () => toggled++,
        onSelected: (index) => selected = index,
      ),
    );

    expect(tester.getSize(_sidebarFinder).width, 48);
    expect(_labelOpacities(tester, 'Proxies'), [0]);
    expect(_rowTooltip('Proxies'), findsOneWidget);
    await tester.tap(_glyph(AppGlyphs.profiles));
    expect(selected, 2);

    await tester.tap(find.byTooltip('Expand'));
    await tester.pump();
    expect(toggled, 1);
    expect(find.text('Proxies'), findsOneWidget);

    await tester.pumpWidget(_sidebar(onToggle: () {}));
    await tester.pump(const Duration(milliseconds: 120));
    final width = tester.getSize(_sidebarFinder).width;
    expect(width, allOf(greaterThan(48), lessThan(220)));
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(tester.getSize(_sidebarFinder).width, 220);
    expect(_rowTooltip('Proxies'), findsNothing);
    expect(find.byTooltip('Collapse'), findsOneWidget);
  });

  testWidgets('an expanded row whose label is cut off keeps its tooltip', (
    tester,
  ) async {
    const long = 'Подключения и активные соединения';
    await tester.pumpWidget(
      _sidebar(
        destinations: const [
          ..._destinations,
          SidebarDestination(glyph: AppGlyphs.connections, label: long),
        ],
        onToggle: () {},
      ),
    );

    expect(_rowTooltip(long), findsOneWidget);
    expect(_rowTooltip('Proxies'), findsNothing);
  });

  testWidgets('the toggle glyph follows the pane as it widens', (tester) async {
    List<Rect> glyph(String tooltip) => [
      for (final shape
          in tester
              .widget<GlyphIcon>(
                find.descendant(
                  of: find.byTooltip(tooltip),
                  matching: find.byType(GlyphIcon),
                ),
              )
              .glyph
              .shapes)
        shape.path.getBounds(),
    ];

    await tester.pumpWidget(_sidebar(expanded: false, onToggle: () {}));
    final collapsed = glyph('Expand');

    await tester.pumpWidget(_sidebar(onToggle: () {}));
    await tester.pump(const Duration(milliseconds: 120));
    final midway = glyph('Collapse');
    expect(midway, isNot(collapsed));

    await tester.pumpAndSettle();
    expect(glyph('Collapse'), isNot(midway));
  });

  testWidgets('window controls keep their corner clear', (tester) async {
    await tester.pumpWidget(
      _sidebar(
        expanded: false,
        onToggle: () {},
        windowControls: const Size(78, 32),
      ),
    );

    final sidebar = tester.getRect(_sidebarFinder);
    expect(sidebar.width, 78);
    final toggle = find.byTooltip('Expand');
    expect(
      tester.getTopLeft(toggle).dy,
      greaterThanOrEqualTo(sidebar.top + 32),
    );
    expect(tester.getCenter(toggle).dx, sidebar.center.dx);
    expect(tester.getCenter(_glyph(AppGlyphs.profiles)).dx, sidebar.center.dx);
    final selectedItem = tester.getRect(
      find
          .ancestor(
            of: _glyph(AppGlyphs.dashboard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(selectedItem.size, const Size(54, 40));
    expect(selectedItem.center.dx, sidebar.center.dx);

    final folder = tester.getCenter(_glyph(AppGlyphs.profiles));
    await tester.pumpWidget(
      _sidebar(onToggle: () {}, windowControls: const Size(78, 32)),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(_sidebarFinder).width, 220);
    expect(tester.getCenter(_glyph(AppGlyphs.profiles)), folder);
  });

  group('without room to widen', () {
    testWidgets('Windows overlay dims the rest without a border or shadow', (tester) async {
      final theme = ThemeData(platform: TargetPlatform.windows);
      final scrim = find.byKey(const ValueKey('sidebar-panel-scrim'));
      await tester.pumpWidget(_sidebar(expanded: false, theme: theme));
      expect(scrim, findsNothing);
      await tester.tap(find.byTooltip('Expand'));
      await tester.pumpAndSettle();
      final pane = tester.widget<Material>(_paneFinder);
      expect(pane.color, panelSurfaceOf(theme.colorScheme));
      expect(pane.elevation, 0);
      expect(pane.shape, isNull);
      expect(pane.shadowColor, Colors.transparent);
      expect(tester.widget<ColoredBox>(scrim).color.a, closeTo(windowsPanelDim, .001));
      await tester.tap(find.byTooltip('Collapse'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(scrim, findsNothing);
      expect(_paneFinder, findsNothing);
    });
    Future<void> openOverlay(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Expand'));
      await tester.pumpAndSettle();
      expect(find.text('Proxies'), findsNWidgets(2));
    }

    testWidgets('the toggle opens the pane over the content', (tester) async {
      await tester.pumpWidget(_sidebar(expanded: false));
      final contentWidth = tester
          .getSize(find.byKey(const ValueKey('content')))
          .width;

      await openOverlay(tester);

      expect(tester.getSize(_sidebarFinder).width, 48);
      expect(
        tester.getSize(find.byKey(const ValueKey('content'))).width,
        contentWidth,
      );
      expect(_labelOpacities(tester, 'Proxies'), unorderedEquals([0, 1]));
      expect(
        tester.getTopLeft(find.byTooltip('Collapse')),
        tester.getTopLeft(find.byTooltip('Expand')),
      );
      final colorScheme = Theme.of(tester.element(_sidebarFinder)).colorScheme;
      final pane = tester.widget<Material>(_paneFinder);
      expect(pane.color, colorScheme.chromeSurface);
      // The pane uses elevation, not the removed contrasting divider.
      expect(pane.shape, isNull);
      expect(pane.elevation, 8);
      expect(pane.shadowColor, colorScheme.shadow);

      await tester.tap(find.byTooltip('Collapse'));
      await tester.pumpAndSettle();
      expect(find.text('Proxies'), findsOneWidget);
    });

    testWidgets('the pane covers the safe area around the sidebar', (
      tester,
    ) async {
      const safePadding = EdgeInsets.only(left: 40, top: 24, bottom: 16);
      await tester.pumpWidget(
        _sidebar(expanded: false, safePadding: safePadding),
      );
      final sidebar = tester.getRect(_sidebarFinder);
      expect(sidebar.width, 48 + safePadding.left);
      final toggle = tester.getTopLeft(find.byTooltip('Expand'));
      expect(toggle.dx, greaterThanOrEqualTo(sidebar.left + safePadding.left));
      expect(toggle.dy, greaterThanOrEqualTo(sidebar.top + safePadding.top));

      await openOverlay(tester);

      final pane = tester.getRect(_paneFinder);
      expect(pane.topLeft, sidebar.topLeft);
      expect(pane.height, sidebar.height);
      expect(pane.width, 220 + safePadding.left);
      expect(tester.getTopLeft(find.byTooltip('Collapse')), toggle);
    });

    testWidgets('choosing a row selects it and closes the pane', (
      tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        _sidebar(expanded: false, onSelected: (index) => selected = index),
      );
      await openOverlay(tester);

      await tester.tap(_shown('Profiles'));
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(find.text('Profiles'), findsOneWidget);
    });

    testWidgets('a tap outside or escape dismisses the pane', (tester) async {
      await tester.pumpWidget(_sidebar(expanded: false));

      await openOverlay(tester);
      await tester.tapAt(const Offset(600, 300));
      await tester.pumpAndSettle();
      expect(find.text('Proxies'), findsOneWidget);

      await openOverlay(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Proxies'), findsOneWidget);
    });

    testWidgets('a tooltip inside the pane lays out over it', (tester) async {
      await tester.pumpWidget(_sidebar(expanded: false));
      await openOverlay(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(
        location: tester.getCenter(find.byTooltip('Collapse')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Collapse'), findsOneWidget);
    });

    testWidgets('window deactivation clears the overlay hit-test barrier', (
      tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        _sidebar(expanded: false, onSelected: (index) => selected = index),
      );
      await openOverlay(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Proxies'), findsOneWidget);

      await tester.tap(_glyph(AppGlyphs.profiles));
      expect(selected, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('metrics changes clear the old overlay anchor and barrier', (
      tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        _sidebar(expanded: false, onSelected: (index) => selected = index),
      );
      await openOverlay(tester);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pump();
      expect(find.text('Proxies'), findsOneWidget);
      await tester.tap(_glyph(AppGlyphs.profiles));
      expect(selected, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('widening the window closes the pane', (tester) async {
      await tester.pumpWidget(_sidebar(expanded: false));
      await openOverlay(tester);

      await tester.pumpWidget(_sidebar(expanded: false, onToggle: () {}));
      await tester.pump();
      expect(find.text('Proxies'), findsOneWidget);
    });
  });
}
