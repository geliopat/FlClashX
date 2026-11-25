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
  Future<String> _windowsStatus(String command) async {
    final root = Platform.environment['SystemRoot'];
    if (root == null) throw StateError('SystemRoot unavailable');
    final exe = p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    final result = await Process.run(exe, ['-NoProfile', '-NonInteractive', '-Command', command])
        .timeout(const Duration(seconds: 12));
    if (result.exitCode != 0) throw StateError('Windows status unavailable');
    return result.stdout.toString().trim();
  }

  Future<void> _run() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    String _t(String ruText, String enText) => ru ? ruText : enText;
    setState(() { _busy = true; _results.clear(); });
    Future<void> check(String name, Future<String> Function() task) async {
      if (!mounted) return;
      String result;
      try {
        result = await task();
      } catch (_) {
        result = l.forkCheckFailed;
      }
      if (mounted) setState(() => _results[name] = result);
    }
    final ok = l.forkPassed;
    final unavailable = l.forkUnavailable;
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
        return '${status.running ? l.forkRunning : l.forkStopped} · ${catalog.length} ${_t('стратегий', 'strategies')}';
      });
      await check(l.forkComponentIntegrity, () async {
        final failures = await checkWindowsComponents();
        return failures.isEmpty ? ok : '${l.forkMissingDamaged}: ${failures.length}';
      });
      await check(l.forkSettingsJson, () async {
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
      await check(l.forkSystemProxy, () async {
        final expected = ref.read(networkSettingProvider).systemProxy && ref.read(isStartProvider);
        // Report only the enable flag; never expose proxy addresses or credentials.
        final actual = await _windowsStatus(
          r"$ErrorActionPreference='Stop'; $v=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -ErrorAction SilentlyContinue; if ($v.ProxyEnable -eq 1) {'1'} else {'0'}",
        );
        if (actual != '0' && actual != '1') return unavailable;
        return 'Configured: $expected · Windows: ${actual == '1'}';
      });
      await check('WinDivert', () async {
        final running = ref.read(zapretControllerProvider).running;
        final drivers = await _windowsStatus(
          r"$ErrorActionPreference='Stop'; Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -like 'WinDivert*' } | ForEach-Object { $_.State }",
        );
        final active = drivers.split(RegExp(r'\s+')).contains('Running');
        if (active) return l.forkRunning;
        return running
            ? _t('Драйвер не найден среди запущенных служб', 'Driver not found among running services')
            : l.forkStopped;
      });
      await check(l.forkServiceJournal, () async {
        await helperClient.zapretLogArchive();
        return ok;
      });
      await check(l.forkNetworkChecks, () async {
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
      padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
        top: context.sectionsTopPadding,
        bottom: 16 + context.bottomInset,
      ),
      children: [
        generateSection(items: [
          ListItem(title: Text(AppLocalizations.of(context).forkRunDiagnostics),
            onTap: _busy ? null : _run,
            trailing: _busy ? const CircularProgressIndicator() : const Icon(Icons.play_arrow)),
          ListItem(title: Text(AppLocalizations.of(context).forkCopyReport),
            onTap: _busy || _results.isEmpty ? null : () async {
              await Clipboard.setData(ClipboardData(text: _results.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n')));
            }),
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
