import 'package:fl_clash/l10n/l10n.dart';
import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/common/common.dart';
import 'package:path/path.dart' as p;

import 'package:fl_clash/common/component_integrity.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class DiagnosticsView extends ConsumerStatefulWidget {
  const DiagnosticsView({super.key});

  @override
  ConsumerState<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends ConsumerState<DiagnosticsView> {
  bool _busy = false;
  final _results = <String, String>{};
  bool get _ru => Localizations.localeOf(context).languageCode == 'ru';
  String _t(String ru, String en) => _ru ? ru : en;

  Future<void> _run() async {
    if (_busy) return;
    setState(() { _busy = true; _results.clear(); });
    Future<void> check(String name, Future<String> Function() task) async {
      String result;
      try {
        result = await task();
      } catch (_) {
        result = AppLocalizations.of(context).forkCheckFailed;
      }
      if (mounted) setState(() => _results[name] = result);
    }
    final ok = AppLocalizations.of(context).forkPassed;
    final unavailable = AppLocalizations.of(context).forkUnavailable;
    try {
      await check('Mihomo', () async {
        if (ref.read(coreStatusProvider) != CoreStatus.connected) return unavailable;
        final core = ref.read(coreHandlerProvider);
        await core.getAppliedHosts();
        final version = await core.getCoreVersion();
        return '$ok · $version';
      });
      await check('Helper / IPC', () async =>
        await helperClient.readiness(timeout: const Duration(seconds: 3), verifyHelperBinary: true) == HelperReadiness.ready ? ok : unavailable);
      await check('Zapret', () async {
        final status = await helperClient.zapretStatus();
        final catalog = await helperClient.zapretStrategies();
        return '${status.running ? AppLocalizations.of(context).forkRunning : AppLocalizations.of(context).forkStopped} · ${catalog.length} ${_t('стратегий', 'strategies')}';
      });
      await check(AppLocalizations.of(context).forkComponentIntegrity, () async {
        final failures = await checkWindowsComponents();
        return failures.isEmpty ? ok : '${AppLocalizations.of(context).forkMissingDamaged}: ${failures.length}';
      });
      await check(AppLocalizations.of(context).forkSettingsJson, () async {
        final saved = await preferences.getConfigMap();
        if (saved == null) return unavailable;
        Config.strictFromJson(saved);
        final current = ref.read(configProvider);
        Config.strictFromJson(jsonDecode(jsonEncode(current)) as Map<String, Object?>);
        return ok;
      });
      await check('TUN', () async {
        if (!ref.read(patchClashConfigProvider).tun.enable || !ref.read(isStartProvider)) {
          return _t('Не запрошен / VPN выключен', 'Not requested / VPN off');
        }
        if (ref.read(coreStatusProvider) != CoreStatus.connected) return unavailable;
        return await ref.read(coreHandlerProvider).getTunFailed()
          ? _t('Ядро сообщает об ошибке TUN', 'Core reports TUN failure')
          : _t('Ядро не сообщает об ошибке TUN (не тест трафика)', 'No TUN failure reported by core (not a traffic test)');
      });
      await check(AppLocalizations.of(context).forkSystemProxy, () async {
        final proxy = ref.read(networkSettingProvider).systemProxy;
        return 'Proxy: $proxy · ${_t('настройка приложения', 'configured state')}';
      });
      await check(AppLocalizations.of(context).forkServiceJournal, () async {
        await helperClient.zapretLogArchive();
        return ok;
      });
      await check(AppLocalizations.of(context).forkNetworkChecks, () async {
        final results = ref.read(zapretDiagnosticsProvider);
        final accepted = ZapretProbeTarget.values.where((target) => results.resultOf(target).accepted).length;
        return '$accepted/${ZapretProbeTarget.values.length} HTTPS · ${_t('последние результаты DIRECT, не доказательство перехвата WinDivert', 'latest DIRECT results, not proof of WinDivert interception')}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CommonScaffold(
    title: AppLocalizations.of(context).forkDiagnostics,
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        generateSection(items: [
          ListItem(title: Text(AppLocalizations.of(context).forkRunDiagnostics),
            onTap: _busy ? null : _run,
            trailing: _busy ? const CircularProgressIndicator() : const Icon(Icons.play_arrow)),
          ListItem(title: Text(AppLocalizations.of(context).forkCopyReport),
            onTap: _busy || _results.isEmpty ? null : () async {
              await Clipboard.setData(ClipboardData(text: _results.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n')));
            }),
        ]),
        generateSection(items: [
          ListItem(
            title: Text(context.appLocalizations.forkSaveDiagnosticReport),
            onTap: _busy || _results.isEmpty ? null : () async {
              try {
                final file = File(p.join(await appPath.downloadDirPath, 'FlClashZ-diagnostics-${DateTime.now().millisecondsSinceEpoch}.txt'));
                await file.writeAsString(_results.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'), flush: true);
                if (context.mounted) dialogs.showNotifier(file.path);
              } catch (_) {
                if (context.mounted) dialogs.showNotifier(context.appLocalizations.forkReportSaveFailed);
              }
            },
          ),
        ]),
        const ListSectionGap(),
        generateSection(title: AppLocalizations.of(context).forkResults, items: [
          for (final entry in _results.entries)
            ListItem(title: Text(entry.key), subtitle: Text(entry.value)),
        ]),
      ],
    ),
  );
}
