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
    final activeSupportsSplitMode =
        active.isNotEmpty && active.first.supportsSplitMode;
    final selected = zapret.strategies.where(
      (item) => item.id == zapret.selectedStrategyId,
    );
    final selectedName = selected.isEmpty ? null : selected.first.name;

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
            ListItem(
              title: const Text('Активный режим'),
              subtitle: Text(
                activeSupportsSplitMode
                    ? zapret.activeMode ?? 'Не определён'
                    : 'Собственные правила стратегии',
              ),
            ),
            ListItem(
              title: const Text('Фильтры WinDivert'),
              subtitle: Text(
                zapret.winDivertFilters.isEmpty
                    ? 'Не переданы'
                    : zapret.winDivertFilters.join(' · '),
                style: TextStyle(fontFamily: 'monospace', color: context.colorScheme.onSurfaceVariant),
              ),
            ),
            ListItem(
              title: const Text('Списки обработки трафика'),
              subtitle: Text(
                zapret.processingLists.isEmpty
                    ? 'Не переданы'
                    : zapret.processingLists.join(' · '),
                style: TextStyle(fontFamily: 'monospace', color: context.colorScheme.onSurfaceVariant),
              ),
            ),
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
