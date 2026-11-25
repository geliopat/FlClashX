import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ListItem;

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
  bool _listLoaded = false;
  bool _saving = false;
  bool _updating = false;
  String? _error;
  String? _notice;
  bool _checkingComponents = false;
  bool _updatingHelper = false;
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
      _listLoaded = false;
      _error = null;
      _notice = null;
    });
    try {
      final lists = await helperClient.zapretLists();
      final currentSelection = _selected;
      final filename = select ??
          (currentSelection != null &&
                  lists.any((item) => item.filename == currentSelection)
              ? currentSelection
              : lists.first.filename);
      final data = await helperClient.readZapretList(filename);
      if (!mounted) return;
      setState(() {
        _lists = lists;
        _selected = filename;
        _editor.text = data.content;
        _loading = false;
        _listLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _listLoaded = false;
        _error = error is HelperException ? error.message : error.toString();
      });
    }
  }

  Future<void> _selectList(String filename) async {
    setState(() {
      _selected = filename;
      _loading = true;
      _listLoaded = false;
      _editor.clear();
      _error = null;
    });
    try {
      final data = await helperClient.readZapretList(filename);
      if (!mounted) return;
      setState(() {
        _editor.text = data.content;
        _loading = false;
        _listLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _listLoaded = false;
        _error = error is HelperException ? error.message : error.toString();
      });
    }
  }

  Future<void> _saveList() async {
    final filename = _selected;
    if (filename == null || !_listLoaded || _saving || _loading) return;
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
    if (filename == null || !_listLoaded || _saving || _updating || _loading) return;
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
    if (_updating || _saving || _lists.isEmpty) return;
    setState(() {
      _updating = true;
      _error = null;
      _notice = null;
    });

    final staged = <String, String>{};
    final originals = <String, String>{};
    final applied = <String>[];
    final details = <String>[];
    final rollbackFailures = <String>[];

    try {
      // Download and validate every upstream file before touching the disk.
      for (final entry in _sources.entries) {
        final current = await helperClient.readZapretList(entry.key);
        final response = await _http.get<String>(entry.value);
        final upstream = response.data;
        if (upstream == null || upstream.trim().length < 20) {
          throw StateError('Источник вернул пустой или слишком короткий файл: ${entry.key}');
        }

        final upstreamCount = upstream
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'))
            .length;
        if (upstreamCount == 0) {
          throw StateError(
            'Обновление ${entry.key} отклонено: источник не содержит записей.',
          );
        }

        // The upstream GUI merges local rows after downloading. Do not compare
        // the upstream count with the installed file: that file may contain
        // many valid local additions which are intentionally retained.
        final merged = _mergeList(upstream, current.content, entry.key);
        if (utf8.encode(merged).length > 2 * 1024 * 1024) {
          throw StateError('Обновлённый файл ${entry.key} превышает лимит 2 МиБ.');
        }
        originals[entry.key] = current.content;
        staged[entry.key] = merged;
      }

      // Apply staged files. Re-read before each write so an edit made in
      // another FlClashX instance during download is not silently overwritten.
      for (final entry in staged.entries) {
        final current = await helperClient.readZapretList(entry.key);
        if (current.content != originals[entry.key]) {
          throw StateError(
            '${entry.key} изменился после загрузки источника. Обновление остановлено, чтобы сохранить параллельную правку.',
          );
        }
        final saved = await helperClient.writeZapretList(entry.key, entry.value);
        applied.add(entry.key);
        details.add('${saved.filename}: ${saved.entries} записей');
      }

      if (!mounted) return;
      await _loadLists(select: _selected);
      if (!mounted) return;
      setState(() {
        _updating = false;
        _notice = 'Обновлено файлов: ${applied.length}. ${details.join(' · ')}. Пользовательские файлы *-user.txt не перезаписывались.';
      });
    } catch (error) {
      // A request can fail after Helper has already replaced the file but
      // before the response reaches the client. Detect that ambiguous case.
      for (final entry in staged.entries) {
        if (applied.contains(entry.key)) continue;
        try {
          final current = await helperClient.readZapretList(entry.key);
          if (current.content == entry.value &&
              current.content != originals[entry.key]) {
            applied.add(entry.key);
          } else if (current.content != originals[entry.key]) {
            rollbackFailures.add(
              '${entry.key}: файл изменился параллельно; автоматический откат пропущен, чтобы не затереть чужую правку.',
            );
          }
        } catch (verificationError) {
          rollbackFailures.add(
            '${entry.key}: не удалось проверить результат записи: $verificationError',
          );
        }
      }

      // Roll back already-applied files in reverse order. Before restoring,
      // verify that nobody has changed the file since this updater wrote it.
      for (final filename in applied.reversed) {
        try {
          final current = await helperClient.readZapretList(filename);
          if (current.content != staged[filename]) {
            rollbackFailures.add(
              '$filename: файл изменился после обновления; автоматический откат пропущен.',
            );
            continue;
          }
          await helperClient.restoreZapretList(filename);
        } catch (rollbackError) {
          rollbackFailures.add('$filename: $rollbackError');
        }
      }
      if (applied.isNotEmpty && mounted) {
        await _loadLists(select: _selected);
      }
      if (!mounted) return;
      setState(() {
        _updating = false;
        _error = error is HelperException ? error.message : error.toString();
        _notice = rollbackFailures.isNotEmpty
            ? 'Не удалось подтвердить или полностью откатить результат: ${rollbackFailures.join('; ')}'
            : applied.isNotEmpty
                ? 'Обновление не завершилось. Изменённые файлы автоматически возвращены из .bak.'
                : null;
      });
    }
  }

  Future<void> _updateHelperService() async {
    if (_updatingHelper) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Переустановить службу Helper?'),
        content: const Text(
          'Служба будет заменена версией из текущей папки FlClashX. '
          'Во время переустановки текущий Mihomo Core может быть остановлен, '
          'а VPN-подключение прервётся. После обновления запусти VPN снова. '
          'Не перемещай и не удаляй папку FlClashX после переустановки службы.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _updatingHelper = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref.read(zapretControllerProvider.notifier).updateHelperService();
      if (!mounted) return;
      setState(() {
        _notice = 'Служба Helper переустановлена. Каталог Zapret2 загружен.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is HelperException ? error.message : error.toString();
      });
    } finally {
      if (mounted) setState(() => _updatingHelper = false);
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
      final upstreamStrategySha = strategies['sha'] is String
          ? strategies['sha'] as String
          : '';
      final upstreamStrategyVersion = upstreamStrategySha.length >= 12
          ? upstreamStrategySha.substring(0, 12)
          : 'неизвестно';
      if (!mounted) return;
      setState(() {
        _componentUpdates = {
          'Zapret2': 'установлено $_installedZapret2 · upstream ${(zapret2['tag_name'] as String?) ?? 'неизвестно'}',
          'Flowseal': 'установлено $_installedFlowseal · upstream ${(flowseal['tag_name'] as String?) ?? 'неизвестно'}',
          'Lua/BAT source': 'установлено ${_installedStrategyCommit.substring(0, 12)} · upstream $upstreamStrategyVersion',
        };
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
    final active = zapret.strategies.where(
      (item) => item.id == zapret.activeStrategyId,
    );
    final activeName = active.isEmpty ? null : active.first.name;
    final activeSupportsSplitMode =
        active.isNotEmpty && active.first.supportsSplitMode;

    final sections = <Widget>[
      generateSection(
        title: 'Состояние',
        items: [
          ListItem(
            leading: Icon(
              zapret.running ? Icons.check_circle_rounded : Icons.pause_circle_outline,
              color: zapret.running
                  ? context.colorScheme.primary
                  : context.colorScheme.onSurfaceVariant,
            ),
            title: const Text('Zapret'),
            subtitle: Text(zapret.running ? 'Запущен' : 'Остановлен'),
          ),
          ListItem(
            title: const Text('Выбранная стратегия'),
            subtitle: Text(zapret.running
                ? activeName ?? 'Не определена'
                : zapret.strategies
                    .where((item) => item.id == zapret.selectedStrategyId)
                    .map((item) => item.name)
                    .firstOrNull ?? 'Не выбрана'),
          ),
          if (zapret.running) ...[
            ListItem(
              title: const Text('Движок и процесс'),
              subtitle: Text(
                '${zapret.activeEngine ?? '—'} · PID ${zapret.pid ?? '—'}',
              ),
            ),
            ListItem(
              title: const Text('Режим'),
              subtitle: Text(
                activeSupportsSplitMode
                    ? zapret.activeMode ?? 'Не определён'
                    : 'Собственные правила стратегии',
              ),
            ),
            ListItem(
              title: const Text('Фильтры WinDivert'),
              subtitle: Text(
                zapret.winDivertFilters.isEmpty
                    ? 'Не переданы'
                    : zapret.winDivertFilters.join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ),
            ListItem(
              title: const Text('Списки обработки трафика'),
              subtitle: Text(
                zapret.processingLists.isEmpty
                    ? 'Не переданы'
                    : zapret.processingLists.join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ),
          ],
          if (zapret.error != null)
            ListItem(
              leading: Icon(Icons.error_outline, color: context.colorScheme.error),
              title: const Text('Ошибка Helper'),
              subtitle: Text(
                zapret.error!,
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.refresh),
            title: const Text('Обновить состояние'),
            onTap: zapret.busy
                ? null
                : () => ref
                    .read(zapretControllerProvider.notifier)
                    .refresh(),
          ),
          if (!zapret.available || zapret.error != null)
            ListItem(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Переустановить Helper'),
              subtitle: const Text(
                'Обновить единую службу Mihomo и Zapret из текущей папки FlClashX',
              ),
              trailing: _updatingHelper
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: zapret.busy || _updatingHelper
                  ? null
                  : _updateHelperService,
            ),
        ],
      ),
      ListSectionGap(),
      generateSection(
        title: 'Сетевые проверки',
        items: [
          for (final target in ZapretProbeTarget.values)
            ListItem(
              title: Text(target.label),
              subtitle: Text(
                diagnostics.resultOf(target).message ?? target.url,
              ),
              trailing: Text(
                diagnostics.resultOf(target).latencyMs == null
                    ? diagnostics.resultOf(target).status.name
                    : '${diagnostics.resultOf(target).latencyMs} ms',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.speed),
            title: const Text('Проверить сейчас'),
            onTap: () => ref
                .read(zapretDiagnosticsProvider.notifier)
                .refresh(),
          ),
        ],
      ),
      ListSectionGap(),
      generateSection(
        title: 'Компоненты Zapret',
        items: [
          ListItem(
            title: const Text('Версии в этой сборке'),
            subtitle: const Text(
              'Zapret2 v1.0.7 · Flowseal 1.10.4 · стратегии geliopat/zapret2-gui',
            ),
          ),
          if (_componentUpdates.isNotEmpty)
            for (final entry in _componentUpdates.entries)
              ListItem(
                title: Text(entry.key),
                subtitle: Text(entry.value),
              ),
          ListItem(
            leading: _checkingComponents
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt),
            title: const Text('Проверить версии'),
            onTap: _checkingComponents ? null : _checkComponentUpdates,
          ),
        ],
        footer:
            'Проверка новых версий выполняется отдельно. Замена winws/winws2, DLL, драйверов WinDivert и Lua/BAT пока не автоматизирована: обновление требует остановки движка, проверки SHA256 и возможности отката.',
      ),
      ListSectionGap(),
      generateSection(
        title: 'Списки Zapret',
        items: [
          if (_error != null)
            ListItem(
              leading: Icon(Icons.error_outline, color: context.colorScheme.error),
              title: const Text('Ошибка'),
              subtitle: Text(
                _error!,
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          if (_notice != null)
            ListItem(
              leading: Icon(Icons.info_outline, color: context.colorScheme.primary),
              title: const Text('Результат операции'),
              subtitle: Text(_notice!),
            ),
          if (_loading && _lists.isEmpty)
            const ListItem(
              title: Text('Загрузка списков…'),
              trailing: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            if (_lists.isNotEmpty && _selected != null)
              ListItem<String>.options(
                title: const Text('Файл списка'),
                options: _lists.map((item) => item.filename).toList(),
                value: _selected!,
                textBuilder: (filename) {
                  final item = _lists.firstWhere(
                    (entry) => entry.filename == filename,
                  );
                  return '$filename · ${item.entries}';
                },
                onChanged: (value) => unawaited(_selectList(value)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: SizedBox(
                height: 260,
                child: TextField(
                  controller: _editor,
                  enabled: _listLoaded && !_loading && !_saving && !_updating,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: SurfaceLevel.inset.colorOf(context.colorScheme),
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: context.colorScheme.outlineVariant,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: context.colorScheme.outlineVariant,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: context.colorScheme.primary,
                        width: 1.5,
                      ),
                    ),
                    hintText: 'Одна запись на строку',
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _loading || _saving || _updating
                        ? null
                        : () => _loadLists(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Перечитать'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: !_listLoaded || _loading || _saving || _updating
                        ? null
                        : _saveList,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: const Text('Сохранить'),
                  ),
                  TextButton.icon(
                    onPressed: _lists.isEmpty || _loading || _saving || _updating
                        ? null
                        : _updateLists,
                    icon: _updating
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download),
                    label: const Text('Обновить списки'),
                  ),
                  TextButton.icon(
                    onPressed: !_listLoaded || _loading || _saving || _updating
                        ? null
                        : _restoreBackup,
                    icon: const Icon(Icons.restore),
                    label: const Text('Откатить .bak'),
                  ),
                ],
              ),
            ),
          ],
        ],
        footer:
            'Обновляются list-general.txt, list-google.txt, list-exclude.txt и ipset-all.txt. Локальные записи сохраняются; файлы *-user.txt не перезаписываются. Перед записью Helper создаёт .bak. После изменения списков перезапусти Zapret. youtube-bad-nodes.txt не меняется, поскольку исходный GUI применяет его через Windows hosts; list-auto.txt пока не активирован в запускателе.',
      ),
    ];

    return CommonScaffold(
      title: 'Zapret',
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: sections,
      ),
    );
  }
}
