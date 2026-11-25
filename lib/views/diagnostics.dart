import 'dart:convert';

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
        result = _t('Ошибка проверки', 'Check failed');
      }
      if (mounted) setState(() => _results[name] = result);
    }
    final ok = _t('Проверено', 'Passed');
    final unavailable = _t('Недоступно', 'Unavailable');
    try {
      await check('Mihomo', () async {
        if (ref.read(coreStatusProvider) != CoreStatus.connected) return unavailable;
        await ref.read(coreHandlerProvider).getAppliedHosts();
        return ok;
      });
      await check('Helper / IPC', () async =>
        await helperClient.readiness(timeout: const Duration(seconds: 3), verifyHelperBinary: true) == HelperReadiness.ready ? ok : unavailable);
      await check('Zapret', () async {
        final status = await helperClient.zapretStatus();
        final catalog = await helperClient.zapretStrategies();
        return '${status.running ? _t('Работает', 'Running') : _t('Остановлен', 'Stopped')} · ${catalog.length} ${_t('стратегий', 'strategies')}';
      });
      await check(_t('Целостность компонентов / WinDivert', 'Component integrity / WinDivert'), () async {
        final failures = await checkWindowsComponents();
        return failures.isEmpty ? ok : '${_t('Повреждены или отсутствуют', 'Missing or damaged')}: ${failures.length}';
      });
      await check(_t('Настройки (JSON)', 'Settings (JSON)'), () async {
        final saved = await preferences.getConfigMap();
        if (saved == null) return unavailable;
        Config.strictFromJson(saved);
        final current = ref.read(configProvider);
        Config.strictFromJson(jsonDecode(jsonEncode(current)) as Map<String, Object?>);
        return ok;
      });
      await check(_t('TUN / системный прокси', 'TUN / system proxy'), () async {
        final tun = ref.read(patchClashConfigProvider).tun.enable;
        final proxy = ref.read(networkSettingProvider).systemProxy;
        return 'TUN: $tun · Proxy: $proxy · ${_t('настройки, не тест трафика', 'configured state, not a traffic test')}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CommonScaffold(
    title: _t('Диагностика', 'Diagnostics'),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        generateSection(items: [
          ListItem(title: Text(_t('Запустить диагностику', 'Run diagnostics')),
            onTap: _busy ? null : _run,
            trailing: _busy ? const CircularProgressIndicator() : const Icon(Icons.play_arrow)),
          ListItem(title: Text(_t('Копировать отчёт', 'Copy report')),
            onTap: _busy || _results.isEmpty ? null : () async {
              await Clipboard.setData(ClipboardData(text: _results.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n')));
            }),
        ]),
        const ListSectionGap(),
        generateSection(title: _t('Результаты', 'Results'), items: [
          for (final entry in _results.entries)
            ListItem(title: Text(entry.key), subtitle: Text(entry.value)),
        ]),
      ],
    ),
  );
}
