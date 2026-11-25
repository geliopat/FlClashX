import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/zapret_components.dart';
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
  bool _updatingHelper = false;

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


  Future<void> _showProtectionList(String title, List<String> entries) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: SelectableText(entries.join('\n')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zapret = ref.watch(zapretControllerProvider);
    final listsBusy = _loading || _saving || _updating || _updatingHelper;
    final sections = <Widget>[
      generateSection(
        title: 'Служба Helper',
        items: [
          ListItem(
            title: const Text('Watchdog Zapret'),
            subtitle: const Text('Восстановление процесса службой Helper, до трёх попыток'),
            trailing: Switch(value: zapret.watchdog, onChanged: ref.read(zapretControllerProvider.notifier).setWatchdog),
          ),
          ListItem(
            title: const Text('Запуск Zapret при старте Mihomo'),
            subtitle: const Text('При остановке Mihomo Zapret также останавливается'),
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
        title: 'Защита соединений Mihomo',
        items: [
          ListItem(
            title: const Text('Исключённые IP и подсети'),
            subtitle: Text('${zapret.protectedIps.length} · автоматически из профиля'),
            onTap: zapret.protectedIps.isEmpty ? null : () => _showProtectionList(
              'Исключённые IP и подсети', zapret.protectedIps,
            ),
          ),
          ListItem(
            title: const Text('Исключённые домены'),
            subtitle: Text('${zapret.protectedDomains.length} · автоматически из профиля'),
            onTap: zapret.protectedDomains.isEmpty ? null : () => _showProtectionList(
              'Исключённые домены', zapret.protectedDomains,
            ),
          ),
          ListItem(
            leading: const Icon(Icons.refresh),
            title: const Text('Обновить исключения'),
            onTap: zapret.busy ? null : () async {
              try {
                await ref.read(zapretControllerProvider.notifier).refreshInfrastructure();
              } catch (error) {
                if (mounted) setState(() => _error = error.toString());
              }
            },
          ),
        ],
        footer: 'hosts, proxies, DNS, fake-ip и route-exclude-address. '
            'Списки создаются отдельно, настройки профиля не меняются.',
      ),
      const ListSectionGap(),
      generateSection(
        title: 'Компоненты Zapret',
        items: [
          for (final entry in installedZapretComponents.entries)
            ListItem(
              title: Text(entry.key),
              subtitle: Text(entry.value),
            ),
        ],
        footer: 'Компоненты обновляются вместе с релизом FlClashZ.',
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
            ),
          if (_lists.isNotEmpty && _selected != null)
            ListItem<String>.options(
              title: const Text('Файл списка'),
              options: _lists.map((item) => item.filename).toList(),
              value: _selected!,
              textBuilder: (filename) {
                final item = _lists.firstWhere(
                  (entry) => entry.filename == filename,
                );
                return '${item.filename} · ${item.entries}';
              },
              onChanged: (value) {
                if (_loading || _saving || _updating || _updatingHelper) return;
                if (value != _selected) unawaited(_selectList(value));
              },
            ),
          if (_selected != null)
            ListItem(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Редактировать список'),
              subtitle: Text(_selected!),
              trailing: const Icon(Icons.chevron_right),
              onTap: !_listLoaded || listsBusy
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
                            if (editorContext.mounted) {
                              Navigator.of(editorContext).pop();
                            }
                          },
                        ),
                      );
                      if (mounted) await _loadLists(select: filename);
                    },
            ),
          ListItem(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('Обновить списки'),
            subtitle: const Text('Загрузить актуальные списки с сохранением локальных записей'),
            trailing: _updating
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _lists.isEmpty || listsBusy ? null : _updateLists,
          ),
          ListItem(
            leading: const Icon(Icons.refresh),
            title: const Text('Перечитать списки'),
            subtitle: const Text('Повторно загрузить файлы с диска'),
            trailing: _loading && _lists.isNotEmpty
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: listsBusy ? null : () => _loadLists(),
          ),
          if (_selected != null)
            ListItem(
              leading: const Icon(Icons.restore),
              title: const Text('Восстановить резервную копию'),
              subtitle: Text('${_selected!}.bak'),
              trailing: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: !_listLoaded || listsBusy ? null : _restoreBackup,
            ),
        ],
        footer:
            'Обновляются 4 основных списка. Пользовательские файлы *-user.txt сохраняются. '
            'Перед записью создаётся .bak. После изменений перезапусти Zapret. '
            'youtube-bad-nodes.txt и list-auto.txt не обновляются.',
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
