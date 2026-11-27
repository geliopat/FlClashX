import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// One settings page, reusing the existing live probe controllers.
class NetworkTestsView extends ConsumerWidget {
  const NetworkTestsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    final url = ref.watch(appSettingProvider.select((s) => s.testUrl));
    final speedService = ref.watch(speedTestSettingsProvider.select((s) => s.service));
    // Keep the saved custom value loaded while showing the preset selector.
    ref.watch(customDelayUrlProvider);
    return CommonScaffold(
      title: ru ? 'Сетевые тесты' : 'Network tests',
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 16 + context.bottomInset),
        children: [
          generateSection(
            title: ru ? 'Задержка' : 'Latency',
            items: [
              const TestUrlItem(),
              if (!delayTestPresets.containsValue(url)) const CustomDelayUrlItem(),
              const DelayTestTimeoutItem(),
              const AutoDelayIntervalItem(active: true),
              const AutoDelayIntervalItem(active: false),
              ConfigToggleItem(
                title: (l) => l.unifiedDelay,
                managedKey: 'clash.unified-delay',
                selector: patchClashConfigProvider.select((s) => s.unifiedDelay),
                onChanged: (ref, value) => ref.read(patchClashConfigProvider.notifier)
                    .update((s) => s.copyWith(unifiedDelay: value)),
              ),
            ],
          ),
          generateSection(
            title: ru ? 'Скорость' : 'Speed',
            items: [
              ListItem(title: const Text('DIRECT'),
                subtitle: const Text('Yandex Internetometer')),
              const SpeedTestUrlItem(),
              if (speedService == SpeedTestService.custom) ...const [
                CustomSpeedUrlItem(upload: false),
                CustomSpeedUrlItem(upload: true),
              ],
            ],
            footer: ru ? 'Тест скорости запускается только вручную.' : 'Speed measurements are manual only.',
          ),
          generateSection(
            title: ru ? 'Доступность сервисов' : 'Service availability',
            items: const [ZapretProbeIntervalItem()],
          ),
        ],
      ),
    );
  }
}
