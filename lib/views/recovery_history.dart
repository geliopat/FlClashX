import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/recovery_journal.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/zapret_logs.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class RecoveryHistoryView extends StatefulWidget {
  const RecoveryHistoryView({super.key});

  @override
  State<RecoveryHistoryView> createState() => _RecoveryHistoryViewState();
}

class _RecoveryHistoryViewState extends State<RecoveryHistoryView> {
  late Future<List<RecoveryEvent>> _events = recoveryJournal.readRecent();

  String _outcome(RecoveryOutcome value, bool ru) => switch (value) {
    RecoveryOutcome.started => ru ? 'Начато' : 'Started',
    RecoveryOutcome.succeeded => ru ? 'Успешно' : 'Succeeded',
    RecoveryOutcome.failed => ru ? 'Ошибка' : 'Failed',
    RecoveryOutcome.interrupted => ru ? 'Прервано' : 'Interrupted',
    RecoveryOutcome.skipped => ru ? 'Пропущено' : 'Skipped',
  };

  String _action(String value, bool ru) => switch (value) {
    'restart' => ru ? 'Перезапуск' : 'Restart',
    'watchdog' => 'Watchdog',
    'watchdog-limit' => ru ? 'Лимит Watchdog' : 'Watchdog limit',
    'reinstall' => ru ? 'Переустановка службы' : 'Reinstall service',
    'restore-service' => ru ? 'Восстановление службы' : 'Restore service',
    _ => value,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    return FutureBuilder<List<RecoveryEvent>>(
      future: _events,
      builder: (context, snapshot) {
        final events = snapshot.data ?? const <RecoveryEvent>[];
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 16 + context.bottomInset),
          itemCount: 1 + events.length,
          separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
          itemBuilder: (context, index) {
            if (index == 0) {
              return generateSection(items: [
                ListItem(title: Text(l.update), leading: const GlyphIcon(AppGlyphs.refresh),
                  onTap: snapshot.connectionState == ConnectionState.waiting ? null :
                    () => setState(() => _events = recoveryJournal.readRecent())),
                ListItem(title: Text(l.openLogsFolder), leading: const GlyphIcon(AppGlyphs.openExternal),
                  onTap: () async => system.openDirectory(await recoveryJournal.directoryPath)),
                ListItem(title: Text(ru ? 'Копировать записи' : 'Copy entries'),
                  onTap: events.isEmpty ? null : () async => Clipboard.setData(ClipboardData(
                    text: events.map((e) => '${e.time.toLocal()} [${e.component}] ${_action(e.action, ru)}: ${_outcome(e.outcome, ru)}').join('\n'),
                  ))),
                ListItem.open(
                  title: Text(ru ? 'События Helper / Zapret' : 'Helper / Zapret events'),
                  widget: const ZapretLogsView(recoveryOnly: true),
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Center(child: CircularProgressIndicator())
                else if (snapshot.hasError)
                  ListItem(title: Text(l.forkLogReadError))
                else if (events.isEmpty)
                  ListItem(title: Text(l.forkNoEvents)),
              ]);
            }
            final event = events[index - 1];
            return RecordListItem(
              onTap: () {},
              header: RecordHeader(children: [
                RecordTimestamp(event.time.toLocal().toString().split('.').first),
                RecordLabel(label: _outcome(event.outcome, ru), tone: switch (event.outcome) {
                  RecoveryOutcome.failed => RecordTone.error,
                  RecoveryOutcome.interrupted || RecoveryOutcome.skipped => RecordTone.warning,
                  _ => RecordTone.neutral,
                }),
              ]),
              body: SelectableText('${event.component} · ${_action(event.action, ru)}',
                style: RecordTextStyles.of(context).primary),
            );
          },
        );
      },
    );
  }
}
