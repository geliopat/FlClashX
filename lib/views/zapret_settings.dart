import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ZapretSettingsView extends ConsumerStatefulWidget {
  const ZapretSettingsView({super.key});

  @override
  ConsumerState<ZapretSettingsView> createState() => _ZapretSettingsViewState();
}

class _ZapretSettingsViewState extends ConsumerState<ZapretSettingsView> {
  static const _installedZapret2 = 'v1.0.7';
  static const _installedFlowseal = '1.10.4';
  static const _installedStrategyCommit = '8dd17fcbcca405a50f497a6e2346ca263901d775';
  static const _sources = <String, String>{
    'list-general.txt': 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/list-general.txt',
    'list-google.txt': 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/list-google.txt',
    'list-exclude.txt': 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/list-exclude.txt',
    'ipset-all.txt': 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/ipset-all.txt',
  };

  static const _gifDomains = <String>[
    'tenor.com', 'media.tenor.com', 'c.tenor.com', 't.tenor.com',
    'api.tenor.com', 'tenor.co', 'gifdeliverynetwork.com', 'giphy.com',
    'media.giphy.com', 'api.giphy.com', 'i.giphy.com',
  ];

  final _editor = TextEditingController();
  final _http = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
  ));

  List<HelperZapretListInfo> _lists = const [];
  String? _selected;
  bool _loading = true;
  bool _saving = false;
  bool _updating = false;
  String? _error;
  String? _notice;
  bool _checkingComponents = false;
  Map<String, String> _componentUpdates = const {};

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (!mounted) return;
      unawaited(_loadLists());
      unawaited(ref.read(zapretDiagnosticsProvider.notifier).refresh());
      unawaited(ref.read(zapretControllerProvider.notifier).refresh());
    });
  }

  @override
  void dispose() {
    _editor.dispose();
    _http.close(force: true);
    super.dispose();
  }

  Future<void> _loadLists({String? select}) async {
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      final lists = await helperClient.zapretLists();
      final filename = select ??
          (_selected != null && lists.any((item) => item.filename == _selected)
              ? _selected
              : lists.first.filename);
      final data = await helperClient.readZapretList(filename);
      if (!mounted) return;
      setState(() {
        _lists = lists;
        _selected = filename;
        _editor.text = data.content;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is HelperException ? error.message : error.toString();
      });
    }
  }

  Future<void> _selectList(String filename) async {
    setState(() {
      _selected = filename;
      _loading = true;
      _error = null;
    });
    try {
      final data = await helperClient.readZapretList(filename);
      if (!mounted) return;
      setState(() {
        _editor.text = data.content;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is HelperException ? error.message : error.toString();
      });
    }
  }

  Future<void> _saveList() async {
    final filename = _selected;
    if (filename == null || _saving || _loading) return;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await helperClient.writeZapretList(filename, _editor.text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _lists = [
          for (final item in _lists)
            if (item.filename == result.filename) result else item,
        ];
        _notice = 'Список сохранён. Резервная копия: $filename.bak';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is HelperException ? error.message : error.toString();
      });
    }
  }

  Future<void> _restoreBackup() async {
    final filename = _selected;
    if (filename == null || _saving || _updating || _loading) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить резервную копию?'),
        content: Text('Текущий $filename будет заменён содержимым $filename.bak. Текущая версия также сохранится в .bak.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await helperClient.restoreZapretList(filename);
      if (!mounted) return;
      await _loadLists(select: filename);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _notice = 'Резервная копия $filename.bak восстановлена. Предыдущая версия сохранена в новой .bak.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is HelperException ? error.message : error.toString();
      });
    }
  }

  String _mergeList(String upstream, String existing, String filename) {
    final seen = <String>{};
    final lines = <String>[];

    void addLine(String raw) {
      final line = raw.trim();
      if (line.isEmpty) return;
      if (line.startsWith('#')) {
        if (!lines.contains(line)) lines.add(line);
        return;
      }
      final key = line.replaceFirst(RegExp(r'^\^'), '').toLowerCase();
      if (seen.add(key)) lines.add(line);
    }

    for (final line in upstream.split(RegExp(r'\r?\n'))) {
      addLine(line);
    }
    // Match zapret2-gui: keep local additions when upstream removes an entry.
    for (final line in existing.split(RegExp(r'\r?\n'))) {
      addLine(line);
    }
    if (filename == 'list-google.txt') addLine('dl.google.com');
    if (filename == 'list-general.txt') {
      for (final domain in _gifDomains) {
        addLine(domain);
      }
    }
    return '${lines.join('\r\n')}\r\n';
  }

  Future<void> _updateLists() async {
    if (_updating || _saving) return;
    setState(() {
      _updating = true;
      _error = null;
      _notice = null;
    });
    var updated = 0;
    final details = <String>[];
    try {
      for (final entry in _sources.entries) {
        final current = await helperClient.readZapretList(entry.key);
        final response = await _http.get<String>(entry.value);
        final upstream = response.data;
        if (upstream == null || upstream.trim().length < 20) {
          throw StateError('Источник вернул пустой или слишком короткий файл: ${entry.key}');
        }
        final merged = _mergeList(upstream, current.content, entry.key);
        final oldCount = current.content
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'))
            .length;
        final newCount = merged
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'))
            .length;
        if (oldCount > 0 && newCount * 2 < oldCount) {
          throw StateError('Обновление ${entry.key} отклонено: число записей резко уменьшилось ($newCount вместо $oldCount).');
        }
        final saved = await helperClient.writeZapretList(entry.key, merged);
        updated++;
        details.add('${saved.filename}: ${saved.entries} записей');
      }
      if (!mounted) return;
      await _loadLists(select: _selected);
      if (!mounted) return;
      setState(() {
        _updating = false;
        _notice = 'Обновлено файлов: $updated. ${details.join(' · ')}. Пользовательские списки не изменялись.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _updating = false;
        _error = error is HelperException ? error.message : error.toString();
        if (updated > 0) {
          _notice = 'До ошибки успешно обновлено файлов: $updated. Для каждого сохранённого файла создан .bak.';
        }
      });
    }
  }

  Future<void> _checkComponentUpdates() async {
    if (_checkingComponents) return;
    setState(() => _checkingComponents = true);
    try {
      final zapret2Response = await _http.get<String>(
        'https://api.github.com/repos/bol-van/zapret2/releases/latest',
        options: Options(headers: const {'Accept': 'application/vnd.github+json'}),
      );
      final flowsealResponse = await _http.get<String>(
        'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest',
        options: Options(headers: const {'Accept': 'application/vnd.github+json'}),
      );
      final strategiesResponse = await _http.get<String>(
        'https://api.github.com/repos/geliopat/zapret2-gui/commits/main',
        options: Options(headers: const {'Accept': 'application/vnd.github+json'}),
      );
      final zapret2 = jsonDecode(zapret2Response.data ?? '') as Map<String, dynamic>;
      final flowseal = jsonDecode(flowsealResponse.data ?? '') as Map<String, dynamic>;
      final strategies = jsonDecode(strategiesResponse.data ?? '') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _componentUpdates = {
          'Zapret2': 'установлено $_installedZapret2 · upstream ${(zapret2['tag_name'] as String?) ?? 'неизвестно'}',
          'Flowseal': 'установлено $_installedFlowseal · upstream ${(flowseal['tag_name'] as String?) ?? 'неизвестно'}',
          'Lua/BAT source': 'установлено ${_installedStrategyCommit.substring(0, 12)} · upstream ${((strategies['sha'] as String?) ?? 'неизвестно').substring(0, 12)}',
        }
        _checkingComponents = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checkingComponents = false;
        _error = 'Не удалось проверить версии компонентов: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final zapret = ref.watch(zapretControllerProvider);
    final diagnostics = ref.watch(zapretDiagnosticsProvider);
    final active = zapret.strategies.where((item) => item.id == zapret.activeStrategyId);
    final activeName = active.isEmpty ? null : active.first.name;

    return CommonScaffold(
      title: 'Zapret',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Состояние',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(zapret.running ? 'Запущен' : 'Остановлен'),
                const SizedBox(height: 4),
                Text('Стратегия: ${activeName ?? 'не активна'}'),
                if (zapret.running) ...[
                  Text('Движок: ${zapret.activeEngine ?? '—'} · PID: ${zapret.pid ?? '—'}'),
                  Text('Режим: ${zapret.activeMode ?? 'собственные правила стратегии'}'),
                  const SizedBox(height: 8),
                  Text('Фильтры перехвата WinDivert', style: Theme.of(context).textTheme.labelLarge),
                  Text(
                    zapret.winDivertFilters.isEmpty ? 'Не переданы' : zapret.winDivertFilters.join(' · '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 8),
                  Text('Списки обработки трафика', style: Theme.of(context).textTheme.labelLarge),
                  Text(
                    zapret.processingLists.isEmpty ? 'Не переданы' : zapret.processingLists.join('\n'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
                if (zapret.error != null)
                  Text(zapret.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: zapret.busy ? null : () => ref.read(zapretControllerProvider.notifier).refresh(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Обновить состояние'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Сетевые проверки',
            child: Column(
              children: [
                for (final target in ZapretProbeTarget.values)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(target.label),
                    subtitle: Text(diagnostics.resultOf(target).message ?? target.url),
                    trailing: Text(
                      diagnostics.resultOf(target).latencyMs == null
                          ? diagnostics.resultOf(target).status.name
                          : '${diagnostics.resultOf(target).latencyMs} ms',
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => ref.read(zapretDiagnosticsProvider.notifier).refresh(),
                    icon: const Icon(Icons.speed),
                    label: const Text('Проверить сейчас'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Компоненты Zapret',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Установленные версии закреплены в сборке FlClashX: Zapret2 v1.0.7, Flowseal 1.10.4 и каталог стратегий geliopat/zapret2-gui.'),
                if (_componentUpdates.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final entry in _componentUpdates.entries)
                    Text('${entry.key}: доступно ${entry.value}'),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: _checkingComponents ? null : _checkComponentUpdates,
                    icon: _checkingComponents
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.system_update_alt),
                    label: const Text('Проверить версии'),
                  ),
                ),
                Text(
                  'Проверка доступных версий работает отдельно. Автоматическая замена winws/winws2, DLL, драйверов WinDivert и Lua/BAT-файлов пока не включена: для неё нужен отдельный staging-процесс с остановкой движка, проверкой SHA256 и откатом всего каталога. До его реализации эти компоненты обновляются вместе с проверенной сборкой FlClashX.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _Section(
            title: 'Списки Zapret',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_notice!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                  ),
                if (_loading && _lists.isEmpty)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  DropdownButtonFormField<String>(
                    value: _selected,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Файл списка'),
                    items: [
                      for (final item in _lists)
                        DropdownMenuItem(
                          value: item.filename,
                          child: Text('${item.filename} · ${item.entries} записей${item.userManaged ? ' · пользовательский' : ''}'),
                        ),
                    ],
                    onChanged: _loading ? null : (value) {
                      if (value != null) unawaited(_selectList(value));
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 300,
                    child: TextField(
                      controller: _editor,
                      enabled: !_loading && !_saving && !_updating,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Одна запись на строку',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _loading || _saving || _updating ? null : () => _loadLists(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Перечитать'),
                      ),
                      FilledButton.icon(
                        onPressed: _loading || _saving || _updating ? null : _saveList,
                        icon: _saving ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
                        label: const Text('Сохранить'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading || _saving || _updating ? null : _updateLists,
                        icon: _updating ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_download),
                        label: const Text('Обновить списки'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading || _saving || _updating ? null : _restoreBackup,
                        icon: const Icon(Icons.restore),
                        label: const Text('Откатить .bak'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Обновляются только list-general.txt, list-google.txt, list-exclude.txt и ipset-all.txt из Flowseal. Локальные записи сохраняются; файлы *-user.txt не перезаписываются. Перед каждой записью Helper создаёт .bak. После изменения списков перезапусти Zapret, чтобы движок перечитал их.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
