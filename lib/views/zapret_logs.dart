import 'dart:async';
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
      title: 'Логи Zapret',
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: 'Журнал Helper',
            items: [
              ListItem<String>.options(
                title: const Text('Фильтр'),
                options: const ['all', 'info', 'error', 'stderr', 'debug'],
                value: _filter,
                textBuilder: (value) => switch (value) {
                  'all' => 'Все события',
                  'info' => 'Информация',
                  'error' => 'Ошибки',
                  'stderr' => 'Вывод stderr',
                  _ => 'Отладка',
                },
                onChanged: (value) => setState(() => _filter = value),
              ),
              if (_error != null)
                ListItem(title: const Text('Ошибка чтения журнала'), subtitle: Text(_error!)),
            ],
            footer: 'Последние 500 событий. Локальный архив собирается в фоне во время работы приложения.',
          ),
          const ListSectionGap(),
          generateSection(
            title: 'Локальные журналы',
            items: [
              ListItem(
                title: const Text('Открыть папку логов Zapret'),
                onTap: () async => system.openDirectory(await zapretFileLogger.directoryPath),
              ),
              ListItem(
                title: const Text('Экспорт сегодняшних логов (ZIP)'),
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
                title: const Text('История аварий и Watchdog'),
                onTap: () async => system.openDirectory(await crashFileLogger.directoryPath),
              ),
            ],
          ),
          const ListSectionGap(),
          generateSection(
            title: 'События',
            items: [
              if (logs.isEmpty) const ListItem(title: Text('Нет событий')),
              for (final entry in logs)
                ListItem(
                  title: Text(entry.message, style: TextStyle(color: switch (entry.level) {
                    'error' => context.colorScheme.error,
                    'stderr' => context.colorScheme.tertiary,
                    'debug' => context.colorScheme.onSurfaceVariant,
                    _ => context.colorScheme.onSurface,
                  })),
                  subtitle: Text('${entry.time.toLocal().toString().split(".").first} · ${entry.level}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
