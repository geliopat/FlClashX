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

    final top = zapret.trials.where((trial) => trial.confirmed).toList()
      ..sort((a, b) => a.delay.compareTo(b.delay));
    Future<void> confirmTrial(ZapretTrial trial) async {
      final name = zapret.strategies.where((item) => item.id == trial.id).firstOrNull?.name ?? trial.id;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Применить стратегию?'),
          content: Text('$name · ${trial.delay} мс'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Применить')),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        try {
          await ref.read(zapretControllerProvider.notifier).applyTrial(trial);
        } catch (error) {
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
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
            title: const Text('Выбранная стратегия'),
            onTap: () => showZapretStrategiesSheet(context),
            subtitle: Text(selectedName ?? 'Не выбрана'),
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
            ListItem(title: const Text('Активная стратегия'), subtitle: Text(activeName ?? 'Не определена')),
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
            subtitle: const Text('Проверка DIRECT через Mihomo, затем подтверждение YouTube, Discord Gateway и Voice. Исходное состояние восстанавливается.'),
            onTap: zapret.busy ? null : () => ref.read(zapretControllerProvider.notifier).testStrategies(),
          ),
          if (zapret.testProgress != null)
            ListItem(title: const Text('Отменить тестирование'), onTap: ref.read(zapretControllerProvider.notifier).cancelTrials),
          if (zapret.testSummary != null)
            ListItem(title: const Text('Результат проверки'), subtitle: Text(zapret.testSummary!, maxLines: 5)),
          if (top.isNotEmpty)
            const ListItem(title: Text('Топ-5 подтверждённых стратегий'), subtitle: Text('Средняя задержка HTTPS · нажми для применения')),
          for (final (index, trial) in top.take(5).indexed)
            ListItem(
              title: Text('${index + 1}. ${zapret.strategies.where((item) => item.id == trial.id).firstOrNull?.name ?? trial.id}'),
              subtitle: Text('${trial.delay} мс · ${trial.score}/6'),
              trailing: zapret.activeStrategyId == trial.id ? const Icon(Icons.check_circle_outline) : null,
              onTap: zapret.busy ? null : () => confirmTrial(trial),
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
