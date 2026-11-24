import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _flowsealRootPreference = 'flowseal.installRoot';

class FlowsealView extends StatefulWidget {
  const FlowsealView({super.key});

  @override
  State<FlowsealView> createState() => _FlowsealViewState();
}

class _FlowsealViewState extends State<FlowsealView> {
  final _rootController = TextEditingController();
  final _tcpController = TextEditingController(text: '12');
  final _udpController = TextEditingController(text: '12');

  String _root = '';
  String _filterMode = 'none';
  String? _selectedStrategy;
  String? _error;
  String? _validation;
  String? _preview;
  FlowsealStatus? _installation;
  FlowsealRuntimeStatus? _runtime;
  List<String> _strategies = const [];
  bool _busy = false;

  bool get _installed => _installation?.installed ?? false;
  bool get _running => _runtime?.running ?? false;
  bool get _elevated => _runtime?.elevated ?? false;

  @override
  void initState() {
    super.initState();
    _restoreSettings();
  }

  @override
  void dispose() {
    _rootController.dispose();
    _tcpController.dispose();
    _udpController.dispose();
    super.dispose();
  }

  Future<void> _restoreSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedRoot = preferences.getString(_flowsealRootPreference);
      final root = savedRoot == null || savedRoot.trim().isEmpty
          ? p.join(await appPath.homeDirPath, 'Flowseal')
          : savedRoot;
      if (savedRoot == null || savedRoot.trim().isEmpty) {
        await preferences.setString(_flowsealRootPreference, root);
      }
      if (!mounted) return;
      setState(() {
        _root = root;
        _rootController.text = root;
      });
      if (root.isNotEmpty) await _refresh();
    } catch (error) {
      _setError('Не удалось загрузить настройки Flowseal: $error');
    }
  }

  void _setError(String? error) {
    if (!mounted) return;
    setState(() => _error = error);
  }

  Future<void> _withBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      _setError(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveRoot() async {
    final root = _rootController.text.trim();
    if (root.isEmpty) {
      _setError('Укажите каталог Flowseal.');
      return;
    }
    await _withBusy(() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_flowsealRootPreference, root);
      if (!mounted) return;
      setState(() {
        _root = root;
        _validation = null;
        _preview = null;
      });
      await _refresh();
    });
  }

  Future<void> _pickRoot() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Выберите каталог Flowseal',
      initialDirectory: _root.isEmpty ? null : _root,
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    _rootController.text = selected;
    await _saveRoot();
  }

  Future<void> _refresh() async {
    if (_root.trim().isEmpty) return;
    final root = _root.trim();
    final installation = await flowsealStatus(root: root);
    final runtime = await flowsealProcessStatus(root: root);
    final strategies = installation.installed
        ? await flowsealListStrategies(root: root)
        : <String>[];
    if (!mounted) return;
    setState(() {
      _installation = installation;
      _runtime = runtime;
      _strategies = strategies;
      if (_selectedStrategy == null ||
          !strategies.contains(_selectedStrategy)) {
        _selectedStrategy = strategies.isEmpty ? null : strategies.first;
      }
      _preview = null;
    });
  }

  Future<void> _validate() async {
    await _withBusy(() async {
      final result = await flowsealValidateInstallation(root: _root);
      if (!mounted) return;
      setState(() => _validation = result);
      await _refresh();
    });
  }

  Future<void> _installOrUpdate() async {
    await _withBusy(() async {
      final result = await flowsealInstallOrUpdate(root: _root);
      if (!mounted) return;
      setState(() => _validation = result);
      await _refresh();
    });
  }

  Future<void> _importStrategy() async {
    if (!_installed) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['bat'],
    );
    if (file == null || !mounted) return;
    await _withBusy(() async {
      if ((file.lengthSync() ?? await file.length()) > 256 * 1024) {
        throw Exception('Размер BAT-файла превышает 256 КиБ.');
      }
      final content = utf8.decode(await file.readAsBytes());
      final name = p.basenameWithoutExtension(file.name).trim();
      await flowsealImportStrategy(root: _root, name: name, content: content);
      await _refresh();
      if (!mounted) return;
      setState(() {
        _selectedStrategy = name;
        _validation = null;
      });
    });
  }

  Future<void> _showPreview() async {
    final strategy = _selectedStrategy;
    if (strategy == null) return;
    await _withBusy(() async {
      final preview = await flowsealParseStrategy(
        root: _root,
        strategy: strategy,
        gameFilterMode: _filterMode,
        gameFilterTcp: _tcpController.text.trim(),
        gameFilterUdp: _udpController.text.trim(),
      );
      if (mounted) setState(() => _preview = preview);
    });
  }

  Future<void> _start() async {
    final strategy = _selectedStrategy;
    if (strategy == null || !_installed) return;
    await _withBusy(() async {
      final status = await flowsealStart(
        root: _root,
        strategy: strategy,
        gameFilterMode: _filterMode,
        gameFilterTcp: _tcpController.text.trim(),
        gameFilterUdp: _udpController.text.trim(),
      );
      if (mounted) setState(() => _runtime = status);
    });
  }

  Future<void> _stop() async {
    await _withBusy(() async {
      final status = await flowsealStop(root: _root);
      if (mounted) setState(() => _runtime = status);
    });
  }

  Future<void> _openLogFolder() async {
    final logPath = _runtime?.logPath;
    if (logPath == null || logPath.isEmpty) return;
    await system.openDirectory(p.dirname(logPath));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return BaseScaffold(
      title: 'Zapret / Flowseal',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 24 + context.bottomInset,
        ),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Локальная интеграция Flowseal',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'FlClashX читает BAT-файлы как описания стратегий. '
                    'Сами BAT/CMD и сценарии установки не запускаются. '
                    'Установка выполняется в выбранный каталог без SYSTEM; '
                    'для записи в него нужны права текущего пользователя.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _rootController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Каталог Flowseal',
                      hintText: r'C:\zapret',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _saveRoot(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickRoot,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Выбрать папку'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _saveRoot,
                        icon: const Icon(Icons.check),
                        label: const Text('Применить'),
                      ),
                      IconButton(
                        tooltip: 'Обновить состояние',
                        onPressed: _busy || _root.isEmpty
                            ? null
                            : () => _withBusy(_refresh),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildInstallationCard(context),
          const SizedBox(height: 12),
          _buildRuntimeCard(context),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  _error!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          if (_installed) ...[
            const SizedBox(height: 12),
            _buildStrategyCard(context),
          ],
        ],
      ),
    );
  }

  Widget _buildInstallationCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final installation = _installation;
    final label = _root.isEmpty
        ? 'Каталог не выбран'
        : installation == null
        ? 'Проверка не выполнена'
        : installation.installed
        ? 'Flowseal найден'
        : 'Установка не обнаружена';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  installation?.installed == true
                      ? Icons.verified
                      : Icons.info_outline,
                  color: installation?.installed == true
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (installation != null) ...[
              const SizedBox(height: 8),
              Text('Версия: ${installation.version}'),
              const SizedBox(height: 4),
              SelectableText(
                installation.executable,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_validation != null) ...[
              const SizedBox(height: 8),
              Text(
                _validation!,
                style: TextStyle(color: colorScheme.primary),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _installOrUpdate,
                  icon: const Icon(Icons.download),
                  label: Text(_installed ? 'Установить обновление' : 'Установить Flowseal'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || !_installed ? null : _validate,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Проверить установку'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRuntimeCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final runtime = _runtime;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Процесс winws.exe', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              _running
                  ? 'Запущен · PID ${runtime?.pid ?? '-'}'
                  : 'Остановлен',
              style: TextStyle(
                color: _running ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
            ),
            if (runtime?.strategy case final strategy?) ...[
              const SizedBox(height: 4),
              Text('Стратегия: $strategy'),
            ],
            const SizedBox(height: 8),
            Text(
              _elevated
                  ? 'Права администратора: есть'
                  : 'Права администратора: нет',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _elevated ? colorScheme.primary : colorScheme.error,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy || !_installed || _running || _selectedStrategy == null
                      ? null
                      : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Запустить'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || !_running ? null : _stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Остановить'),
                ),
                TextButton.icon(
                  onPressed: runtime == null || runtime.logPath.isEmpty
                      ? null
                      : _openLogFolder,
                  icon: const Icon(Icons.folder),
                  label: const Text('Папка логов'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStrategyCard(BuildContext context) {
    final enabled = _strategies.isNotEmpty && !_busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Стратегии', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            if (_strategies.isEmpty)
              const Text('BAT-стратегии в выбранном каталоге не найдены.')
            else
              DropdownButtonFormField<String>(
                initialValue: _selectedStrategy,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Стратегия',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final strategy in _strategies)
                    DropdownMenuItem(
                      value: strategy,
                      child: Text(strategy, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _selectedStrategy = value;
                        _preview = null;
                      }),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _filterMode,
              decoration: const InputDecoration(
                labelText: 'Игровой фильтр',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Отключён')),
                DropdownMenuItem(value: 'all', child: Text('TCP + UDP')),
                DropdownMenuItem(value: 'tcp', child: Text('Только TCP')),
                DropdownMenuItem(value: 'udp', child: Text('Только UDP')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _filterMode = value ?? 'none';
                      _preview = null;
                    }),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tcpController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'TCP-порты',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() => _preview = null),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _udpController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'UDP-порты',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _preview = null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: enabled && _selectedStrategy != null
                      ? _showPreview
                      : null,
                  icon: const Icon(Icons.code),
                  label: const Text('Просмотр аргументов'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importStrategy,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Импортировать BAT'),
                ),
              ],
            ),
            if (_preview != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                _preview!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
