import 'package:fl_clash/ui/keyed_animated_list.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildList(List<String> items) {
    return MaterialApp(
      home: Scaffold(
        body: KeyedAnimatedList<String>(
          items: items,
          keyOf: (item) => item,
          separator: const Divider(height: 0),
          itemBuilder: (_, item) => SizedBox(
            key: ValueKey('row-$item'),
            height: 40,
            child: Text(item),
          ),
        ),
      ),
    );
  }

  double topOf(WidgetTester tester, String item) {
    return tester.getTopLeft(find.byKey(ValueKey('row-$item'))).dy;
  }

  testWidgets('removed item collapses before leaving the tree', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b', 'c']));
    await tester.pumpWidget(buildList(const ['a', 'c']));
    await tester.pump();

    expect(find.text('b'), findsOneWidget);
    final midway = topOf(tester, 'c');
    await tester.pump(const Duration(milliseconds: 150));
    expect(topOf(tester, 'c'), lessThan(midway));

    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(topOf(tester, 'c'), 40);
  });

  testWidgets('reordered item slides from its old slot', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b', 'c']));
    expect(topOf(tester, 'c'), 80);

    await tester.pumpWidget(buildList(const ['c', 'a', 'b']));
    await tester.pump();

    final render = tester.renderObject(find.byKey(const ValueKey('row-c')));
    Offset paintedTop() => (render as RenderBox).localToGlobal(Offset.zero);
    expect(paintedTop().dy, closeTo(80, 0.01));

    await tester.pump(const Duration(milliseconds: 150));
    final midway = paintedTop().dy;
    expect(midway, greaterThan(0));
    expect(midway, lessThan(80));

    await tester.pumpAndSettle();
    expect(paintedTop().dy, closeTo(0, 0.01));
    expect(tester.takeException(), null);
  });

  testWidgets('item inserted and removed before it grows is dropped', (
    tester,
  ) async {
    await tester.pumpWidget(buildList(const ['a']));
    await tester.pumpWidget(buildList(const ['a', 'b']));
    await tester.pumpWidget(buildList(const ['a']));
    expect(tester.takeException(), null);

    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('item removed and re-added keeps a single row', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b']));
    await tester.pumpWidget(buildList(const ['a']));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(buildList(const ['a', 'b']));
    await tester.pumpAndSettle();

    expect(find.text('b'), findsOneWidget);
    expect(topOf(tester, 'b'), 40);
  });

  testWidgets('rows entering in one update share a single ticker', (
    tester,
  ) async {
    final visible = [for (var i = 0; i < 30; i++) '$i'];
    await tester.pumpWidget(buildList(visible));
    await tester.pumpWidget(
      buildList([...visible, for (var i = 30; i < 70; i++) '$i']),
    );
    await tester.pump();

    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a change too large to animate swaps the rows at once', (
    tester,
  ) async {
    final many = [for (var i = 0; i < 100; i++) '$i'];
    await tester.pumpWidget(buildList(many));
    await tester.pumpWidget(buildList(const ['0', '1']));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(KeyedAnimatedList<String>),
        matching: find.byType(SizeTransition),
      ),
      findsNothing,
    );
    expect(find.text('2'), findsNothing);
    expect(topOf(tester, '1'), 40);

    await tester.pumpWidget(buildList(many));
    await tester.pump();
    expect(find.text('10'), findsOneWidget);
    expect(topOf(tester, '10'), 400);
  });
  for (final count in [1000, 10000]) {
    testWidgets('large feed $count rows stays lazy across refresh and scroll', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var builds = 0;
      Widget fixture(List<int> ids) => MaterialApp(
        home: Scaffold(
          body: KeyedAnimatedList<int>(
            items: ids,
            keyOf: (id) => id,
            controller: scroll,
            itemBuilder: (_, id) {
              builds++;
              return SizedBox(height: 40, child: Text('row-$id'));
            },
          ),
        ),
      );
      final ids = List.generate(count, (i) => i);
      await tester.pumpWidget(fixture(ids));
      expect(builds, lessThan(200));
      expect(find.text('row-0'), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(fixture(List.of(ids)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(builds, lessThan(1000));
      scroll.jumpTo(8000);
      await tester.pumpAndSettle();
      expect(find.text('row-200'), findsOneWidget);
      await tester.pumpWidget(fixture([for (final id in ids) if (id != 0) id, count]));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(builds, lessThan(1500));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

}
