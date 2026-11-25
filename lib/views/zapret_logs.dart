import 'dart:async';

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
  bool _paused = false;
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
    if (_paused || _loading || !mounted) return;
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

  Future<void> _clear() async {
    try {
      await helperClient.clearZapretLogs();
      if (mounted) setState(() => _logs = const []);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
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
              ListItem(
                title: Text(_paused ? 'Продолжить' : 'Приостановить'),
                onTap: () {
                  setState(() => _paused = !_paused);
                  if (!_paused) unawaited(_refresh());
                },
              ),
              ListItem(title: const Text('Очистить журнал'), onTap: _clear),
              if (_error != null)
                ListItem(title: const Text('Ошибка чтения журнала'), subtitle: Text(_error!)),
            ],
            footer: 'Последние 500 событий. Подробный вывод движка настраивается в общих настройках.',
          ),
          const ListSectionGap(),
          generateSection(
            title: 'События',
            items: [
              if (logs.isEmpty) const ListItem(title: Text('Нет событий')),
              for (final entry in logs)
                ListItem(
                  title: Text(entry.message, style: TextStyle(color: context.colorScheme.onSurface)),
                  subtitle: Text('${entry.time.toLocal().toString().split(".").first} · ${entry.level}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
