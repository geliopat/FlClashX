import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:fl_clash/views/dashboard/widgets/zapret_strategy_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class ZapretView extends ConsumerWidget {
  const ZapretView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zapret = ref.watch(zapretControllerProvider);
    final diagnostics = ref.watch(zapretDiagnosticsProvider);
    final active = zapret.strategies.where(
      (item) => item.id == zapret.activeStrategyId,
    );
    final activeName = active.isEmpty ? null : active.first.name;
    final selected = zapret.strategies.where(
      (item) => item.id == zapret.selectedStrategyId,
    );
    final selectedName = selected.isEmpty ? null : selected.first.name;

    final confirmedTrials = zapret.trials.where((trial) => trial.confirmed).length;
    final errors = zapret.trials.where((trial) => trial.error != null).length;
    final screened = zapret.trials.where((trial) =>
        trial.screenedOnly && trial.error == null && trial.passedTargets > 0).length;
    final partial = zapret.trials.where((trial) =>
        !trial.confirmed && !trial.screenedOnly && trial.error == null && trial.passedTargets > 0).length;
    final failed = zapret.trials.length - confirmedTrials - errors - screened - partial;
    Future<void> showAllTrials() async {
      await BaseNavigator.push<void>(context, const ZapretResultsView());
    }

    Widget details(String title, List<String> values) => ListItem(
      title: Text(title),
      subtitle: Text(values.isEmpty ? 'Не переданы' : '${values.length} · Нажми для просмотра'),
      onTap: values.isEmpty ? null : () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 650, child: SingleChildScrollView(
            child: SelectableText(values.join('\n\n'), style: const TextStyle(fontFamily: 'monospace')),
          )),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Закрыть'))],
        ),
      ),
    );

    final sections = <Widget>[
      generateSection(
        title: 'Состояние',
        items: [
          ListItem(
            leading: Icon(
              zapret.running ? Icons.check_circle_rounded : Icons.pause_circle_outline,
              color: zapret.running
                  ? context.colorScheme.primary
                  : context.colorScheme.onSurfaceVariant,
            ),
            title: const Text('Zapret'),
            subtitle: Text(zapret.running ? 'Запущен' : 'Остановлен'),
          ),
          ListItem(
            title: Text(zapret.running ? 'Остановить Zapret' : 'Запустить Zapret'),
            leading: Icon(zapret.running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            onTap: zapret.busy || !zapret.available ? null : () => ref.read(zapretControllerProvider.notifier).setEnabled(!zapret.running),
          ),
          if (zapret.running)
            ListItem(
              title: const Text('Перезапустить Zapret'),
              onTap: zapret.busy ? null : () => ref.read(zapretControllerProvider.notifier).restart(),
            ),
          ListItem(
            title: const Text('Стратегия'),
            onTap: zapret.busy ? null : () => showZapretStrategiesSheet(context),
            subtitle: Text(
              zapret.running && zapret.activeStrategyId != zapret.selectedStrategyId
                  ? 'Выбрана: ${selectedName ?? zapret.selectedStrategyId}\nРаботает: ${activeName ?? zapret.activeStrategyId ?? 'Не определена'}'
                  : selectedName ?? 'Не выбрана',
              maxLines: 3,
            ),
          ),
          if (zapret.supportsSplitMode)
            ListItem<ZapretMode>.options(
              title: const Text('Выбранный режим'),
              options: ZapretMode.values,
              value: zapret.mode,
              textBuilder: (mode) => mode == ZapretMode.strictSplit ? 'STRICT SPLIT' : 'FULL BYPASS',
              onChanged: (mode) => ref.read(zapretControllerProvider.notifier).setMode(mode),
            ),
          if (zapret.running) ...[
            ListItem(
              title: const Text('Движок и процесс'),
              subtitle: Text(
                '${zapret.activeEngine ?? '—'} · PID ${zapret.pid ?? '—'}',
              ),
            ),
            details('Фильтры WinDivert', zapret.winDivertFilters),
            details('Списки обработки трафика', zapret.processingLists),
          ],
          if (zapret.error != null)
            ListItem(
              leading: Icon(Icons.error_outline, color: context.colorScheme.error),
              title: const Text('Ошибка Helper'),
              subtitle: Text(
                zapret.error!,
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.refresh),
            title: const Text('Обновить состояние'),
            onTap: zapret.busy
                ? null
                : () => ref
                    .read(zapretControllerProvider.notifier)
                    .refresh(),
          ),
        ],
      ),
      const ListSectionGap(),
      generateSection(
        title: 'Автоподбор стратегий',
        items: [
          ListItem(
            title: Text(zapret.testProgress ?? 'Проверить все стратегии'),
            subtitle: const Text('Быстрый отбор всех стратегий и контроль лучших кандидатов через Mihomo DIRECT. YouTube, GoogleVideo и два HTTPS API Discord.'),
            onTap: zapret.busy ? null : () => ref.read(zapretControllerProvider.notifier).testStrategies(),
          ),
          if (zapret.testProgress != null)
            ListItem(title: const Text('Отменить тестирование'), onTap: ref.read(zapretControllerProvider.notifier).cancelTrials),
          if (zapret.testSummary != null || zapret.trials.isNotEmpty)
            ListItem(
              title: const Text('Результат проверки'),
              subtitle: Text([
                if (zapret.testSummary != null) zapret.testSummary!,
                'Успешно: $confirmedTrials · частично: $partial',
                'Не прошли: $failed · ошибки: $errors',
                'Только отбор: $screened · без результата: ${(zapret.strategies.length - zapret.trials.length).clamp(0, zapret.strategies.length)}',
                'Нажми для просмотра всех стратегий и топ-5',
              ].join('\n'), maxLines: 8),
              trailing: const Icon(Icons.chevron_right),
              onTap: showAllTrials,
            ),
          ListItem(
            title: const Text('Автоматический переход на резервную стратегию'),
            subtitle: const Text('Три неудачные проверки, только подтверждённые кандидаты, откат при неудаче'),
            trailing: Switch(value: zapret.autoFallback,
              onChanged: ref.read(zapretControllerProvider.notifier).setAutoFallback),
          ),
        ],
      ),
      const ListSectionGap(),
      generateSection(
        title: 'Сетевые проверки',
        items: [
          for (final target in ZapretProbeTarget.values)
            ListItem(
              title: Text(target.label),
              subtitle: Text(
                diagnostics.resultOf(target).message ?? target.url,
              ),
              trailing: Text(
                diagnostics.resultOf(target).latencyMs == null
                    ? diagnostics.resultOf(target).status.name
                    : '${diagnostics.resultOf(target).latencyMs} ms',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.speed),
            title: const Text('Проверить сейчас'),
            onTap: () => ref
                .read(zapretDiagnosticsProvider.notifier)
                .refresh(),
          ),
        ],
      ),
      const ListSectionGap(),
    ];
    return CommonScaffold(
      title: 'Zapret',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: sections,
      ),
    );
  }
}

class ZapretResultsView extends ConsumerWidget {
  const ZapretResultsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zapret = ref.watch(zapretControllerProvider);
    final ranked = shortlistZapretTrials(zapret.trials, limit: zapret.trials.length);
    final top = shortlistZapretTrials(ranked.where((trial) =>
        trial.error == null && (trial.confirmed || trial.passedTargets > 0)), limit: 5);
    final ranks = {for (final (index, trial) in top.indexed) trial.id: index + 1};

    String nameOf(ZapretTrial trial) => zapret.strategies
        .where((item) => item.id == trial.id).firstOrNull?.name ?? trial.id;

    Future<void> apply(ZapretTrial trial) async {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Применить стратегию?'),
          content: Text('${nameOf(trial)} · ${trial.delay} мс'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Применить')),
          ],
        ),
      );
      if (accepted != true || !context.mounted) return;
      try {
        await ref.read(zapretControllerProvider.notifier).applyTrial(trial);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }

    return CommonScaffold(
      title: 'Результаты автоподбора',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          Text('Проверено: ${ranked.length}/${zapret.strategies.length}',
            style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(top.isEmpty
              ? 'Нет стратегий с успешными запросами.'
              : 'Топ-5 выделены цветом и номером. Подтверждённые можно применить.'),
          const Text('Задержки HTTPS, не ICMP. Три обязательных проверки; GoogleVideo — дополнительная. Discord Voice API: restricted означает доступность HTTPS, а не проверку голосового UDP.'),
          const SizedBox(height: 12),
          for (final trial in ranked)
            Card(
              color: ranks.containsKey(trial.id) ? context.colorScheme.primaryContainer : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text(
                        '${ranks.containsKey(trial.id) ? 'ТОП ${ranks[trial.id]} · ' : ''}${nameOf(trial)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      )),
                      if (zapret.activeStrategyId == trial.id)
                        const Icon(Icons.check_circle_outline),
                      if (trial.confirmed)
                        TextButton(onPressed: zapret.busy ? null : () => apply(trial), child: const Text('Применить')),
                    ]),
                    Text('${trial.resultLabel} · ${trial.passedTargets}/3 обязательных · '
                        '${trial.delay > 0 ? '${trial.delay} мс (среднее)' : 'Нет задержки'}'),
                    if (trial.error != null)
                      Text(trial.error!, style: TextStyle(color: context.colorScheme.error)),
                    for (final detail in trial.details)
                      SelectableText(detail),
                    if (trial.details.isEmpty)
                      const Text('Измерения не получены'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
