import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:fl_clash/ui/title_tabs.dart';
import 'package:material_ui/material_ui.dart';

String _levelLabel(AppLocalizations l, String level) => switch (level) {
  'info' => l.forkInfo,
  'error' => l.error,
  'stderr' => l.forkStderr,
  'debug' => l.forkDebug,
  _ => level,
};

typedef _JournalEntry = ({HelperZapretLog log, String component});

class ZapretLogsView extends StatefulWidget {
  const ZapretLogsView({super.key, this.journalOnly = false});

  final bool journalOnly;

  @override
  State<ZapretLogsView> createState() => _ZapretLogsViewState();
}

class _ZapretLogsViewState extends State<ZapretLogsView>
    with WidgetsBindingObserver, ActivePollingMixin<ZapretLogsView> {
  late int _tab = widget.journalOnly ? 2 : 0;
  bool _loading = false;
  String _query = '';
  String _filter = 'all';
  String? _error;
  List<HelperZapretLog> _logs = const [];
  Future<List<_JournalEntry>>? _archive;

  @override
  Duration get pollInterval => _tab == 0
      ? const Duration(seconds: 2)
      : const Duration(seconds: 30);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    if (_tab != 0) {
      if (isCurrent()) _reloadArchive();
      return;
    }
    if (_loading || !isCurrent()) return;
    _loading = true;
    try {
      final logs = await helperClient.zapretLogs();
      if (isCurrent() && _tab == 0) {
        setState(() { _logs = logs; _error = null; });
      }
    } catch (error) {
      if (isCurrent() && _tab == 0) {
        setState(() => _error = error.toString());
      }
    } finally {
      _loading = false;
    }
  }

  bool _readingArchive = false;

  void _reloadArchive() {
    if (!mounted || _readingArchive) return;
    _readingArchive = true;
    final future = _loadArchive();
    setState(() => _archive = future);
    // Observe the original future even if the user leaves the page before
    // FutureBuilder subscribes. Keep its error available for the UI.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _readingArchive = false));
  }

  Future<List<_JournalEntry>> _loadArchive() async {
    final archive = await helperClient.zapretLogArchive();
    final events = <_JournalEntry>[];
    for (final line in const LineSplitter().convert(archive)) {
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        final log = HelperZapretLog.fromJson(decoded);
        final component = decoded is Map
            ? decoded['component']?.toString() ?? 'Zapret'
            : 'Zapret';
        events.add((log: log, component: component));
      } catch (_) {
        // An interrupted final write cannot hide other events.
      }
    }
    return events.reversed.toList(growable: false);
  }

  void _selectTab(int value) {
    if (_tab == value) return;
    setState(() {
      _tab = value;
      _filter = 'all';
    });
    restartPolling();
  }

  bool _matches(_JournalEntry entry) {
    final log = entry.log;
    if (_tab == 1 && log.level != 'error' &&
        !log.message.toLowerCase().contains('watchdog') &&
        !log.message.toLowerCase().contains('engine exited')) return false;
    return (_filter == 'all' || log.level == _filter) &&
        '${entry.component} ${log.level} ${log.message}'
            .toLowerCase().contains(_query.toLowerCase());
  }

  Widget _record(BuildContext context, _JournalEntry entry) {
    final log = entry.log;
    return RecordListItem(
      onTap: () {},
      header: RecordHeader(children: [
        RecordTimestamp(log.time.toLocal().toString().split('.').first),
        RecordLabel(
          label: _levelLabel(AppLocalizations.of(context), log.level),
          tone: switch (log.level) {
            'error' => RecordTone.error,
            'stderr' => RecordTone.warning,
            _ => RecordTone.neutral,
          },
        ),
      ]),
      body: SelectableText(
        _tab == 0 ? log.message : '[${entry.component}] ${log.message}',
        style: RecordTextStyles.of(context).primary,
      ),
    );
  }

  Widget _filterSection(BuildContext context, {String? error}) {
    final l = AppLocalizations.of(context);
    return generateSection(
      items: [
        ListItem<String>.options(
          title: Text(l.forkFilter),
          options: const ['all', 'info', 'error', 'stderr', 'debug'],
          value: _filter,
          textBuilder: (value) => switch (value) {
            'all' => l.forkAllEvents,
            'error' => l.forkErrors,
            _ => _levelLabel(l, value),
          },
          onChanged: (value) => setState(() => _filter = value),
        ),
        if (_tab != 0)
          ListItem(
            title: Text(l.update),
            trailing: const Icon(Icons.refresh),
            onTap: _reloadArchive,
          ),
        if (error != null)
          ListItem(title: Text(l.forkLogReadError), subtitle: Text(error)),
      ],
      footer: _tab == 0 ? l.forkLogFooter : null,
    );
  }

  Widget _entriesView(BuildContext context, List<_JournalEntry> entries, {String? error}) {
    final filtered = entries.where(_matches).toList(growable: false);
    final l = AppLocalizations.of(context);
    return ListView.separated(
      key: ValueKey(_tab),
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding + 12, 16, 16 + context.bottomInset),
      itemCount: 1 + (filtered.isEmpty ? 1 : filtered.length),
      separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
      itemBuilder: (context, index) {
        if (index == 0) return _filterSection(context, error: error);
        if (filtered.isEmpty) return ListItem(title: Text(l.forkNoEvents));
        return _record(context, filtered[index - 1]);
      },
    );
  }

  Widget _journal(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FutureBuilder<List<_JournalEntry>>(
      future: _archive,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.forkJournalUnavailable),
              TextButton(
                onPressed: _reloadArchive,
                child: Text(l.retry),
              ),
            ],
          ));
        }
        return _entriesView(context, snapshot.data ?? const []);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return CommonScaffold(
      title: widget.journalOnly ? l.forkServiceJournal : l.forkZapretLogs,
      titleWidget: widget.journalOnly ? null : PageTitleTabs(
        labels: [l.forkEvents, l.forkCrashHistory],
        selectedIndex: _tab,
        onSelected: _selectTab,
      ),
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      body: Builder(
        builder: (context) => _tab == 0
            ? _entriesView(context, [
                for (final log in _logs.reversed)
                  (log: log, component: 'Zapret'),
              ], error: _error)
            : _journal(context),
      ),
    );
  }
}
