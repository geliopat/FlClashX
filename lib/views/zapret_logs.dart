import 'package:fl_clash/l10n/l10n.dart';
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/file_logger.dart';

import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class ZapretLogsView extends ConsumerStatefulWidget {
  const ZapretLogsView({super.key});

  @override
  ConsumerState<ZapretLogsView> createState() => _ZapretLogsViewState();
}

class _ZapretLogsViewState extends ConsumerState<ZapretLogsView> {
  Timer? _timer;
  bool _loading = false;
  String _query = '';
  String _filter = 'all';
  String? _error;
  List<HelperZapretLog> _logs = const [];

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_refresh);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading || !mounted) return;
    _loading = true;
    try {
      final logs = await helperClient.zapretLogs();
      if (mounted) setState(() { _logs = logs; _error = null; });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = _logs.reversed.where((entry) =>
      (_filter == 'all' || entry.level == _filter) &&
      entry.message.toLowerCase().contains(_query.toLowerCase())
    ).toList();
    return CommonScaffold(
      title: AppLocalizations.of(context).forkZapretLogs,
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: AppLocalizations.of(context).forkHelperJournal,
            items: [
              ListItem<String>.options(
                title: Text(AppLocalizations.of(context).forkFilter),
                options: const ['all', 'info', 'error', 'stderr', 'debug'],
                value: _filter,
                textBuilder: (value) => switch (value) {
                  'all' => AppLocalizations.of(context).forkAllEvents,
                  'info' => AppLocalizations.of(context).forkInfo,
                  'error' => AppLocalizations.of(context).forkErrors,
                  'stderr' => AppLocalizations.of(context).forkStderr,
                  _ => AppLocalizations.of(context).forkDebug,
                },
                onChanged: (value) => setState(() => _filter = value),
              ),
              if (_error != null)
                ListItem(title: Text(AppLocalizations.of(context).forkLogReadError), subtitle: Text(_error!)),
            ],
            footer: 'Последние 500 событий. Локальный архив собирается в фоне во время работы приложения.',
          ),
          const ListSectionGap(),
          generateSection(
            title: AppLocalizations.of(context).forkLocalLogs,
            items: [
              ListItem(
                title: Text(AppLocalizations.of(context).forkOpenZapretLogs),
                onTap: () async => system.openDirectory(await zapretFileLogger.directoryPath),
              ),
              ListItem(
                title: Text(AppLocalizations.of(context).forkExportTodayLogs),
                onTap: () async {
                  try {
                    final archive = await zapretFileLogger.archiveToday(await appPath.downloadDirPath);
                    if (!context.mounted) return;
                    if (archive == null) {
                      dialogs.showNotifier('Нет сохранённых логов за сегодня');
                    } else {
                      dialogs.showNotifier('Архив сохранён: $archive');
                    }
                  } catch (_) {
                    if (context.mounted) dialogs.showNotifier('Не удалось экспортировать логи');
                  }
                },
              ),
              ListItem(
                title: Text(AppLocalizations.of(context).forkCrashHistory),
                onTap: () async => system.openDirectory(await crashFileLogger.directoryPath),
              ),
            ],
          ),
          const ListSectionGap(),
          generateSection(
            items: [
              ListItem(
                title: Text(context.appLocalizations.forkExportServiceJournal),
                onTap: () async {
                  try {
                    final content = await helperClient.zapretLogArchive();
                    final stamp = DateTime.now().millisecondsSinceEpoch;
                    final file = File(p.join(await appPath.downloadDirPath, 'FlClashZ-service-$stamp.jsonl'));
                    await file.writeAsString(content, flush: true);
                    if (context.mounted) dialogs.showNotifier(file.path);
                  } catch (_) {
                    if (context.mounted) dialogs.showNotifier(context.appLocalizations.forkJournalUnavailable);
                  }
                },
              ),
            ],
          ),
          const ListSectionGap(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(AppLocalizations.of(context).forkEvents,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (logs.isEmpty) ListItem(title: Text(AppLocalizations.of(context).forkNoEvents)),
          for (final entry in logs) ...[
                RecordListItem(
                  onTap: () {},
                  header: RecordHeader(children: [
                    RecordTimestamp(entry.time.toLocal().toString().split('.').first),
                    RecordLabel(
                      label: entry.level,
                      tone: switch (entry.level) {
                        'error' => RecordTone.error,
                        'stderr' => RecordTone.warning,
                        _ => RecordTone.neutral,
                      },
                    ),
                  ]),
                  body: SelectableText(entry.message, style: RecordTextStyles.of(context).primary),
                ),
                const SizedBox(height: recordListGap),
          ],
        ],
      ),
    );
  }
}
