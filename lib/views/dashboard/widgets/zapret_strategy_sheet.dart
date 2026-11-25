import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';

Future<void> showZapretStrategiesSheet(BuildContext context) {
  return showSheet<void>(
    context: context,
    builder: (_) => const ZapretStrategySheet(),
  );
}

/// The same three strategy families used by zapret2-gui's selector:
/// Flowseal, built-in zapret2 Lua profiles, and the imported kinlay0 set.
class ZapretStrategySheet extends ConsumerWidget {
  const ZapretStrategySheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zapretControllerProvider);
    final strategies = state.strategies;
    final flowseal = strategies.where((item) => item.engine == 'winws').toList();
    final zapret2 = strategies
        .where(
          (item) =>
              item.engine == 'winws2' && !item.id.startsWith('kinlay0-'),
        )
        .toList();
    final kinlay0 = strategies
        .where((item) => item.id.startsWith('kinlay0-'))
        .toList();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: DefaultTabController(
            length: 3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Стратегии Zapret',
                        style: AppTextStyle.title3.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                    ),
                    DashboardIconButton(
                      glyph: AppGlyphs.close,
                      tooltip: context.appLocalizations.close,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const TabBar(
                  isScrollable: false,
                  tabs: [
                    Tab(text: 'Flowseal'),
                    Tab(text: 'Zapret2'),
                    Tab(text: 'kinlay0'),
                  ],
                ),
                const SizedBox(height: 8),
                if (state.supportsSplitMode) ...[
                  SegmentedButton<ZapretMode>(
                    segments: const [
                      ButtonSegment(
                        value: ZapretMode.strictSplit,
                        label: Text('STRICT SPLIT'),
                      ),
                      ButtonSegment(
                        value: ZapretMode.fullBypass,
                        label: Text('FULL BYPASS'),
                      ),
                    ],
                    selected: {state.mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) {
                      ref
                          .read(zapretControllerProvider.notifier)
                          .setMode(selection.first)
                          .catchError((error) {
                        dialogs.showNotifier(
                          error.toString(),
                          level: MessageLevel.error,
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 5),
                  Text(
                    state.mode == ZapretMode.strictSplit
                        ? 'Десинхронизация только для YouTube, Discord и Google-сервисов из списка. YouTube QUIC не затрагивается.'
                        : 'Десинхронизация на всех перехваченных портах выбранного пресета.',
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                ] else if (strategies.isNotEmpty) ...[
                  Text(
                    'Для этой стратегии режимы STRICT SPLIT / FULL BYPASS не применяются: используются собственные правила конфигурации.',
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                ],
                if (strategies.isEmpty)
                  Expanded(
                    child: Center(
                      child: state.error == null
                          ? const CircularProgressIndicator()
                          : Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    state.error!,
                                    textAlign: TextAlign.center,
                                    style: AppTextStyle.footnote.of(context).copyWith(
                                          color: context.colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton.tonalIcon(
                                    onPressed: () => ref
                                        .read(zapretControllerProvider.notifier)
                                        .loadStrategies(),
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Повторить'),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  )
                else
                  Expanded(
                    child: TabBarView(
                      children: [
                        _ZapretStrategyList(strategies: flowseal),
                        _ZapretStrategyList(strategies: zapret2),
                        _ZapretStrategyList(strategies: kinlay0),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  state.running && state.activeStrategyId != null
                      ? 'Работает: ${_strategyName(strategies, state.activeStrategyId!)} · ${state.activeEngine}. Новый режим применится после перезапуска.'
                      : 'Выбранная стратегия и режим применятся при следующем запуске',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _strategyName(
    List<HelperZapretStrategy> strategies,
    String id,
  ) {
    for (final item in strategies) {
      if (item.id == id) return item.name;
    }
    return id;
  }
}

class _ZapretStrategyList extends ConsumerWidget {
  const _ZapretStrategyList({required this.strategies});

  final List<HelperZapretStrategy> strategies;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (strategies.isEmpty) {
      return Center(
        child: Text(
          'В этой группе нет стратегий',
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final state = ref.watch(zapretControllerProvider);
    return FrostedGroup(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: strategies.length,
        itemBuilder: (context, index) {
          final strategy = strategies[index];
          final selected = strategy.id == state.selectedStrategyId;
          final active = strategy.id == state.activeStrategyId;
          return ItemPositionProvider(
            position: ItemPosition.get(index, strategies.length),
            child: DecorationListItem(
              isSelected: selected || active,
              title: Text(
                strategy.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${strategy.description} · ${strategy.engine}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: active
                  ? Tooltip(
                      message: 'Сейчас работает',
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: context.colorScheme.success,
                      ),
                    )
                  : selected
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: context.colorScheme.primary,
                        )
                      : null,
              onPressed: () async {
                try {
                  await ref
                      .read(zapretControllerProvider.notifier)
                      .selectStrategy(strategy.id);
                  if (context.mounted) Navigator.of(context).maybePop();
                } catch (error) {
                  dialogs.showNotifier(
                    error.toString(),
                    level: MessageLevel.error,
                  );
                }
              },
            ),
          );
        },
      ),
    );
  }
}
