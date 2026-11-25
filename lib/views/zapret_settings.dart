import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/pages/editor.dart';

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
  bool _listLoaded = false;
  bool _saving = false;
  bool _updating = false;
  String? _error;
  String? _notice;
  bool _checkingComponents = false;
  bool _updatingHelper = false;
  Map<String, String> _componentUpdates = const {
    'Zapret2': 'установлено $_installedZapret2 · upstream не проверен',
    'Flowseal': 'установлено $_installedFlowseal · upstream не проверен',
    'Lua/BAT source': 'установлено $_installedStrategyCommit · upstream не проверен',
  };

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
              : (lists.isEmpty ? null : lists.first.filename));
      if (filename == null) {
        if (mounted) setState(() { _lists = lists; _selected = null; _loading = false; });
        return;
      }
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

  Future<void> _restoreBackup() async {
    final filename = _selected;
    if (filename == null || !_listLoaded || _saving || _updating || _loading) return;
    final confirmed = await showFloatingDialog<bool>(
      context: context,
      child: CommonDialog(
        title: 'Восстановить резервную копию?',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Восстановить'),
          ),
        ],
        child: Text('Текущий $filename будет заменён содержимым $filename.bak. Текущая версия также сохранится в .bak.'),
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
        if (upstream == null || (entry.key != 'ipset-all.txt' && upstream.trim().length < 20)) {
          throw StateError('Источник вернул пустой или слишком короткий файл: ${entry.key}');
        }

        final upstreamCount = upstream
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'))
            .length;
        if (upstreamCount == 0 && entry.key != 'ipset-all.txt') {
          throw StateError(
            'Обновление ${entry.key} отклонено: источник не содержит записей.',
          );
        }

        if (entry.key == 'ipset-all.txt' && upstreamCount == 0) {
          details.add('ipset-all.txt: пустой шаблон, локальный файл сохранён');
          continue;
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
    final confirmed = await showFloatingDialog<bool>(
      context: context,
      child: CommonDialog(
        title: 'Переустановить службу Helper?',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Продолжить'),
          ),
        ],
        child: const Text(
          'Служба будет заменена версией из текущей папки FlClashX. '
          'Во время переустановки Helper остановит Mihomo Core и Zapret, '
          'поэтому VPN и обход временно прервутся. После обновления запусти их снова. '
          'Не перемещай и не удаляй папку FlClashX после переустановки службы.',
        ),
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
    final sections = <Widget>[
      generateSection(
        title: 'Служба Helper',
        items: [
          ListItem(
            title: const Text('Watchdog Zapret'),
            subtitle: const Text('Восстановление процесса после сбоя, до трёх попыток'),
            trailing: Switch(value: zapret.watchdog, onChanged: ref.read(zapretControllerProvider.notifier).setWatchdog),
          ),
          ListItem(
            title: const Text('Запуск Zapret при старте Mihomo'),
            subtitle: const Text('Движки можно останавливать независимо'),
            trailing: Switch(
              value: zapret.startWithMihomo,
              onChanged: ref.read(zapretControllerProvider.notifier).setStartWithMihomo,
            ),
          ),
            ListItem(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Переустановить Helper'),
              subtitle: const Text(
                'Обновить единую службу Mihomo и Zapret из текущей папки FlClashZ',
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
      const ListSectionGap(),
      generateSection(
        title: 'Компоненты Zapret',
        items: [
          const ListItem(
            title: Text('Версии в этой сборке'),
            subtitle: Text(
              'Zapret2 v1.0.7 · Flowseal 1.10.4 · стратегии geliopat/zapret2-gui',
            ),
          ),
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
      const ListSectionGap(),
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
            if (_selected != null)
              ListItem(
                title: const Text('Редактировать список'),
                subtitle: Text(_selected!),
                onTap: !_listLoaded || _loading || _saving || _updating
                    ? null
                    : () async {
                        final filename = _selected!;
                        await BaseNavigator.push<void>(
                          context,
                          EditorPage(
                              title: filename,
                              content: _editor.text,
                              onSave: (editorContext, title, content) async {
                                final text = await content.readText();
                                await helperClient.writeZapretList(filename, text);
                                if (editorContext.mounted) Navigator.of(editorContext).pop();
                              },
                          ),
                        );
                        if (mounted) await _loadLists(select: filename);
                      },
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
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: sections,
      ),
    );
  }
}
