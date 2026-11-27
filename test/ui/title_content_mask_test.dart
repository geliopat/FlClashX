import 'package:fl_clash/ui/title_content_mask.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('mask is compact, grows with title and mirrors RTL', () {
    const body = Rect.fromLTWH(0, 0, 1000, 800);
    const short = Rect.fromLTWH(50, 18, 71, 28);
    const long = Rect.fromLTWH(50, 18, 290, 28);
    final a = titleMaskExtent(body, short, TextDirection.ltr);
    final b = titleMaskExtent(body, long, TextDirection.ltr);
    expect(a.width, 147);
    expect(a.height, 65);
    expect(b.width, greaterThan(a.width));
    final rtl = titleMaskExtent(body, const Rect.fromLTWH(879, 18, 71, 28), TextDirection.rtl);
    expect(rtl.width, a.width);
    expect(rtl.right, body.right);
  });
  testWidgets('mask keeps its content mounted across anchor changes', (tester) async {
    final anchor = ValueNotifier<Rect?>(null);
    addTearDown(anchor.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: ValueListenableBuilder<Rect?>(
      valueListenable: anchor,
      child: SizedBox(key: key, width: 100, height: 100),
      builder: (_, rect, child) => TitleContentMask(title: rect, child: child!),
    )));
    final element = key.currentContext;
    anchor.value = const Rect.fromLTWH(20, 10, 60, 30);
    await tester.pump();
    expect(key.currentContext, same(element));
    expect(tester.takeException(), isNull);
  });
}
