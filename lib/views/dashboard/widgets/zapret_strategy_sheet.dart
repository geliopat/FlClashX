import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showZapretStrategiesSheet(BuildContext context) {
  return showSheet<void>(
    context: context,
    builder: (_) => const ZapretStrategySheet(),
  );
}

class ZapretStrategySheet extends ConsumerWidget {
  const ZapretStrategySheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zapretControllerProvider);
    final controller = ref.read(zapretControllerProvider.notifier);
    final families = {
      'Flowseal': state.strategies.where((s) => s.engine == 'winws'),
      'Zapret2': state.strategies.where(
        (s) => s.engine == 'winws2' && !s.id.startsWith('kinlay0-'),
      ),
      'kinlay0': state.strategies.where((s) => s.id.startsWith('kinlay0-')),
    };
    return CommonScaffold(
      title: 'Стратегии Zapret',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          if (state.supportsSplitMode)
            generateSection(
              title: 'Режим',
              items: [
                ListItem<ZapretMode>.options(
                  title: const Text('Режим обработки'),
                  options: ZapretMode.values,
                  value: state.mode,
                  textBuilder: (mode) => mode == ZapretMode.strictSplit
                      ? 'STRICT SPLIT'
                      : 'FULL BYPASS',
                  onChanged: (mode) async {
                    try {
                      await controller.setMode(mode);
                    } catch (error) {
                      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
                    }
                  },
                ),
              ],
              footer: 'Выбранный режим применяется при следующем запуске Zapret.',
            ),
          if (state.strategies.isEmpty)
            generateSection(
              items: [
                ListItem(
                  title: const Text('Каталог стратегий недоступен'),
                  subtitle: Text(state.error ?? 'Загрузка…'),
                  onTap: controller.loadStrategies,
                ),
              ],
            ),
          for (final family in families.entries)
            if (family.value.isNotEmpty) ...[
              const ListSectionGap(),
              generateSection(
                title: family.key,
                items: [
                  for (final strategy in family.value)
                    ListItem(
                      title: Text(strategy.name),
                      subtitle: Text(strategy.description),
                      trailing: strategy.id == state.activeStrategyId
                          ? Icon(Icons.play_circle_fill_rounded, color: context.colorScheme.success)
                          : strategy.id == state.selectedStrategyId
                              ? Icon(Icons.check_circle_rounded, color: context.colorScheme.primary)
                              : null,
                      onTap: state.busy ? null : () async {
                        try {
                          await controller.selectStrategy(strategy.id);
                        } catch (error) {
                          dialogs.showNotifier(error.toString(), level: MessageLevel.error);
                        }
                      },
                    ),
                ],
              ),
            ],
        ],
      ),
    );
  }
}
