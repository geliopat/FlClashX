import 'package:fl_clash/providers/appearance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('glow live preview and queued writes persist the final choice', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(glowIntensityProvider.notifier);
    controller.preview(.4);
    expect(container.read(glowIntensityProvider), .4);
    final first = controller.save(.8);
    final last = controller.save(0);
    await Future.wait([first, last]);
    final store = await SharedPreferences.getInstance();
    expect(store.getDouble(glowIntensityPreferenceKey), 0);
    expect(container.read(glowIntensityProvider), 0);
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(glowIntensityProvider);
    await Future<void>.delayed(Duration.zero);
    expect(restored.read(glowIntensityProvider), 0);
  });
}
