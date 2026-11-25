import 'package:fl_clash/l10n/l10n.dart';
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
        !trial.confirmed && !trial.screenedOnly && trial.error == null && trial.score > 0).length;
    final failed = zapret.trials.length - confirmedTrials - errors - screened - partial;
    Future<void> showAllTrials() async {
      await BaseNavigator.push<void>(context, const ZapretResultsView());
    }

    Future<void> chooseTestMode() async {
      final mode = await showDialog<ZapretAutoTuneMode>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppLocalizations.of(context).forkAutoTuneMode),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in ZapretAutoTuneMode.values)
                ListItem(
                  title: Text(mode.localizedLabel(AppLocalizations.of(context))),
                  subtitle: Text(mode.localizedDescription(AppLocalizations.of(context))),
                  onTap: () => Navigator.of(ctx).pop(mode),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(AppLocalizations.of(context).cancel)),
          ],
        ),
      );
      if (mode != null && context.mounted) {
        await ref.read(zapretControllerProvider.notifier).testStrategies(tuneMode: mode);
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
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(AppLocalizations.of(context).close))],
        ),
      ),
    );

    final sections = <Widget>[
      generateSection(
        title: AppLocalizations.of(context).forkState,
        items: [
          ListItem(
            leading: Icon(
              zapret.running ? Icons.check_circle_rounded : Icons.pause_circle_outline,
              color: zapret.running
                  ? context.colorScheme.primary
                  : context.colorScheme.onSurfaceVariant,
            ),
            title: const Text('Zapret'),
            subtitle: Text(zapret.running ? AppLocalizations.of(context).forkStarted : AppLocalizations.of(context).forkStopped),
          ),
          ListItem(
            title: Text(zapret.running ? AppLocalizations.of(context).forkStopZapret : AppLocalizations.of(context).forkStartZapret),
            leading: Icon(zapret.running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            onTap: zapret.busy || !zapret.available ? null : () => ref.read(zapretControllerProvider.notifier).setEnabled(!zapret.running),
          ),
          if (zapret.running)
            ListItem(
              title: Text(AppLocalizations.of(context).forkRestartZapret),
              onTap: zapret.busy ? null : () => ref.read(zapretControllerProvider.notifier).restart(),
            ),
          ListItem(
            title: Text(AppLocalizations.of(context).forkStrategy),
            onTap: zapret.busy ? null : () => showZapretStrategiesSheet(context),
            subtitle: Text(
              zapret.running && zapret.activeStrategyId != zapret.selectedStrategyId
                  ? 'Выбрана: ${selectedName ?? zapret.selectedStrategyId}\nРаботает: ${activeName ?? zapret.activeStrategyId ?? AppLocalizations.of(context).forkUndefined}'
                  : selectedName ?? AppLocalizations.of(context).forkNotSelected,
              maxLines: 3,
            ),
          ),
          if (zapret.supportsSplitMode)
            ListItem<ZapretMode>.options(
              title: Text(AppLocalizations.of(context).forkSelectedMode),
              options: ZapretMode.values,
              value: zapret.mode,
              textBuilder: (mode) => mode == ZapretMode.strictSplit ? 'STRICT SPLIT' : 'FULL BYPASS',
              onChanged: (mode) => ref.read(zapretControllerProvider.notifier).setMode(mode),
            ),
          if (zapret.running) ...[
            ListItem(
              title: Text(AppLocalizations.of(context).forkEngineProcess),
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
              title: Text(AppLocalizations.of(context).forkHelperError),
              subtitle: Text(
                zapret.error!,
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.refresh),
            title: Text(AppLocalizations.of(context).forkRefreshStatus),
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
        title: AppLocalizations.of(context).forkAutoTune,
        items: [
          ListItem(
            title: Text(zapret.testProgress ?? AppLocalizations.of(context).forkStartAutoTune),
            subtitle: const Text('Очень быстрый, быстрый или полный · Mihomo DIRECT'),
            onTap: zapret.busy ? null : chooseTestMode,
          ),
          if (zapret.testProgress != null)
            ListItem(title: Text(AppLocalizations.of(context).forkCancelTest), onTap: ref.read(zapretControllerProvider.notifier).cancelTrials),
          if (zapret.testSummary != null || zapret.trials.isNotEmpty)
            ListItem(
              title: Text(AppLocalizations.of(context).forkTestResult),
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
            leading: const Icon(Icons.history),
            title: Text(AppLocalizations.of(context).forkAutoTuneHistory),
            subtitle: Text(AppLocalizations.of(context).forkLastThirtyRuns),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => BaseNavigator.push<void>(context, const _ZapretHistoryView()),
          ),
          ListItem(
            title: Text(AppLocalizations.of(context).forkAutoFallback),
            subtitle: const Text('Три неудачные проверки, только подтверждённые кандидаты, откат при неудаче'),
            trailing: Switch(value: zapret.autoFallback,
              onChanged: ref.read(zapretControllerProvider.notifier).setAutoFallback),
          ),
        ],
      ),
      const ListSectionGap(),
      generateSection(
        title: AppLocalizations.of(context).forkNetworkChecks,
        items: [
          for (final target in ZapretProbeTarget.values)
            ListItem(
              title: Text(target.label),
              subtitle: Text(
                diagnostics.resultOf(target).message ?? target.url,
              ),
              trailing: Text(
                diagnostics.resultOf(target).latencyMs == null
                    ? diagnostics.resultOf(target).localizedStatusLabel(AppLocalizations.of(context))
                    : '${diagnostics.resultOf(target).latencyMs} ms',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.speed),
            title: Text(AppLocalizations.of(context).forkCheckNow),
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

String _runDate(DateTime at) => at.toLocal().toString().split('.').first;

class _ZapretHistoryView extends StatefulWidget {
  const _ZapretHistoryView();

  @override
  State<_ZapretHistoryView> createState() => _ZapretHistoryViewState();
}

class _ZapretHistoryViewState extends State<_ZapretHistoryView> {
  late final Future<List<ZapretTuneRun>> _runs = loadZapretTuneHistory();

  @override
  Widget build(BuildContext context) => CommonScaffold(
    title: AppLocalizations.of(context).forkAutoTuneHistory,
    body: FutureBuilder<List<ZapretTuneRun>>(
      future: _runs,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Не удалось прочитать историю: ${snapshot.error}'));
        }
        final runs = snapshot.data ?? const <ZapretTuneRun>[];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (runs.isEmpty) Center(child: Text(AppLocalizations.of(context).forkEmptyHistory)),
            for (final run in runs)
              Card(child: ListItem(
                title: Text(_runDate(run.at)),
                subtitle: Text([
                  run.tuneMode?.localizedLabel(AppLocalizations.of(context)) ?? AppLocalizations.of(context).forkPreviousRun,
                  if (run.duration != null) 'Длительность: ${run.duration!.inSeconds} с',
                  'Проверено: ${run.trials.length}${run.totalStrategies == null ? '' : '/${run.totalStrategies}'} · успешно: ${run.trials.where((trial) => trial.confirmed).length}',
                  if (run.failure != null) AppLocalizations.of(context).forkCompletedWithError,
                ].join('\n')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => BaseNavigator.push<void>(context, ZapretResultsView(run: run)),
              )),
          ],
        );
      },
    ),
  );
}

class ZapretResultsView extends ConsumerWidget {
  const ZapretResultsView({super.key, this.run});
  final ZapretTuneRun? run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zapret = ref.watch(zapretControllerProvider);
    final trials = run?.trials ?? zapret.trials;
    final ranked = shortlistZapretTrials(trials, limit: trials.length);
    final top = shortlistZapretTrials(ranked.where((trial) =>
        !trial.screenedOnly && trial.error == null && trial.score > 0), limit: 5);
    final ranks = {for (final (index, trial) in top.indexed) trial.id: index + 1};

    String nameOf(ZapretTrial trial) => zapret.strategies
        .where((item) => item.id == trial.id).firstOrNull?.name ?? trial.id;

    Future<void> apply(ZapretTrial trial) async {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppLocalizations.of(context).forkApplyStrategy),
          content: Text('${nameOf(trial)} · ${trial.delay} мс'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(AppLocalizations.of(context).cancel)),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(AppLocalizations.of(context).submit)),
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
      title: AppLocalizations.of(context).forkTuneResults,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          if (run != null) ...[
            Text(_runDate(run!.at)),
            if (run!.summary != null) Text(run!.summary!),
            if (run!.failure != null) Text(run!.failure!, style: TextStyle(color: context.colorScheme.error)),
          ],
          Text('Проверено: ${ranked.length}/${run == null ? zapret.strategies.length : run!.totalStrategies ?? '—'}',
            style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(top.isEmpty
              ? 'Нет финалистов с положительной оценкой. Предварительный отбор показан отдельно.'
              : run == null ? 'Топ-5 выделены цветом и номером. Подтверждённые можно применить.' : 'Топ-5 выделены цветом и номером. История доступна только для просмотра.'),
          const Text('Баллы: работает — 2, с ограничениями — 1, нет ответа — 0. Полный тест: 0–6; отбор: только YouTube, 0–2. GoogleVideo — дополнительный. Discord Voice API не проверяет голосовой UDP.'),
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
                      if (run == null && zapret.activeStrategyId == trial.id)
                        const Icon(Icons.check_circle_outline),
                      if (run == null && trial.confirmed)
                        TextButton(onPressed: zapret.busy ? null : () => apply(trial), child: Text(AppLocalizations.of(context).submit)),
                    ]),
                    Text('${trial.localizedResultLabel(AppLocalizations.of(context))} · ${trial.score}/${trial.screenedOnly ? 2 : 6} баллов · '
                        '${trial.delay > 0 ? '${trial.delay} мс (среднее)' : 'Нет задержки'}'),
                    if (trial.screenedOnly)
                      const Text('Discord и GoogleVideo не проверялись'),
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
