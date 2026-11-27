import 'package:fl_clash/providers/material_appearance.dart';
import 'package:fl_clash/ui/material_appearance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('separate material preferences survive queued writes and reload', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(materialAppearanceProvider.notifier);
    final value = decodeMaterialAppearance({
      'windowOpacity': 0,
      'card': {'effect': 'micaAlt', 'opacity': .65},
      'button': {'effect': 'acrylic', 'blur': 16},
    });
    controller.preview(value);
    expect(container.read(materialAppearanceProvider), value);
    final first = controller.save(defaultMaterialAppearance);
    final last = controller.save(value);
    await Future.wait([first, last]);
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(materialAppearanceProvider);
    await Future<void>.delayed(Duration.zero);
    expect(restored.read(materialAppearanceProvider), value);
  });
}
