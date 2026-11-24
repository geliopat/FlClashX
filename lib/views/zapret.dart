import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _flowsealRootPreference = 'flowseal.installRoot';
const _flowsealStrategyPreference = 'flowseal.selectedStrategy';

const _flowsealUserLists = <String, String>{
  'list-general-user.txt': 'Домены для обработки Zapret',
  'list-exclude-user.txt': 'Домены вне обработки Zapret',
  'ipset-exclude-user.txt': 'IP-адреса и подсети-исключения',
};

class FlowsealView extends StatefulWidget {
  const FlowsealView({super.key});

  @override
  State<FlowsealView> createState() => _FlowsealViewState();
}

class _FlowsealViewState extends State<FlowsealView> {
  final _rootController = TextEditingController();
  final _tcpController = TextEditingController(text: '1024-65535');
  final _udpController = TextEditingController(text: '1024-65535');
  final _listEntryController = TextEditingController();
  final _listSearchController = TextEditingController();

  String _root = '';
  String _selectedUserList = _flowsealUserLists.keys.first;
  List<String> _userListEntries = const [];
  bool _listLoading = false;
  String _ipsetMode = 'any';
  String? _ipsetUpdateMessage;
  String _filterMode = 'none';
  String? _selectedStrategy;
  String? _error;
  String? _validation;
  String? _preview;
  FlowsealStatus? _installation;
  FlowsealRuntimeStatus? _runtime;
  List<String> _strategies = const [];
  bool _busy = false;
  bool _pollingStatus = false;
  String _listQuery = '';
  String _testType = 'combined';
  bool _testing = false;
  bool _testWasCancelled = false;
  FlowsealStrategyTestProgress? _testProgress;
  List<FlowsealStrategyTestResult> _testResults = const [];
  StreamSubscription<FlowsealStrategyTestProgress>? _testSubscription;
  Timer? _statusTimer;

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
    _statusTimer?.cancel();
    _rootController.dispose();
    _tcpController.dispose();
    _udpController.dispose();
    _testSubscription?.cancel();
    _listEntryController.dispose();
    _listSearchController.dispose();
    super.dispose();
  }

  Future<void> _restoreSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedRoot = preferences.getString(_flowsealRootPreference);
      final savedStrategy = preferences.getString(_flowsealStrategyPreference);
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
        _selectedStrategy = savedStrategy;
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
    if (_busy || _testing) return;
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

  Future<void> _selectStrategy(String strategy) async {
    if (_busy || _testing || !_strategies.contains(strategy)) return;
    setState(() {
      _selectedStrategy = strategy;
      _preview = null;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_flowsealStrategyPreference, strategy);
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

  void _syncStatusPolling() {
    if (_running) {
      _statusTimer ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_pollRuntimeStatus()),
      );
    } else {
      _statusTimer?.cancel();
      _statusTimer = null;
    }
  }

  Future<void> _pollRuntimeStatus() async {
    if (!mounted || _busy || _pollingStatus || _root.trim().isEmpty) return;
    _pollingStatus = true;
    try {
      final status = await flowsealProcessStatus(root: _root);
      if (!mounted) return;
      setState(() => _runtime = status);
      _syncStatusPolling();
    } catch (_) {
      // A transient status read must not hide the current runtime state.
    } finally {
      _pollingStatus = false;
    }
  }

  Future<void> _refresh() async {
    if (_root.trim().isEmpty) return;
    final root = _root.trim();
    final installation = await flowsealStatus(root: root);
    final runtime = await flowsealProcessStatus(root: root);
    final strategies = installation.installed
        ? await flowsealListStrategies(root: root)
        : <String>[];
    final userListEntries = installation.installed
        ? await flowsealReadUserList(root: root, filename: _selectedUserList)
        : <String>[];
    final gameFilter = installation.installed
        ? await flowsealGetGameFilter(root: root)
        : null;
    final ipsetMode = installation.installed
        ? await flowsealIpSetStatus(root: root)
        : null;
    if (!mounted) return;
    setState(() {
      _installation = installation;
      _runtime = runtime;
      _strategies = strategies;
      _userListEntries = userListEntries;
      if (ipsetMode != null) _ipsetMode = ipsetMode;
      if (gameFilter != null) {
        _filterMode = gameFilter.mode;
        _tcpController.text = gameFilter.tcpRange;
        _udpController.text = gameFilter.udpRange;
      }
      if (_selectedStrategy == null ||
          !strategies.contains(_selectedStrategy)) {
        _selectedStrategy = strategies.isEmpty ? null : strategies.first;
      }
      _preview = null;
    });
    _syncStatusPolling();
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
    if (!_installed || _busy || _testing) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['bat'],
    );
    if (file == null || !mounted) return;

    final initialName = p.basenameWithoutExtension(file.name).trim();
    final name = await dialogs.showCommonDialog<String>(
      child: InputDialog(
        title: 'Импорт стратегии',
        value: initialName,
        hintText: 'Имя стратегии',
        maxLength: 64,
        validator: (value) {
          final candidate = value?.trim() ?? '';
          if (candidate.isEmpty) return 'Укажите имя стратегии.';
          if (candidate.length > 64 ||
              !RegExp(r'^[a-zA-Z0-9 _.-]+$').hasMatch(candidate) ||
              candidate == '.' ||
              candidate == '..' ||
              candidate.toLowerCase() == 'service') {
            return 'Допустимы латинские буквы, цифры, пробел, точка, дефис и подчёркивание.';
          }
          return null;
        },
      ),
    );
    if (name == null || !mounted) return;

    await _withBusy(() async {
      final length = file.lengthSync() ?? await file.length();
      if (length == 0 || length > 256 * 1024) {
        throw Exception('BAT-файл пустой или превышает 256 КиБ.');
      }
      final content = utf8
          .decode(await file.readAsBytes(), allowMalformed: true)
          .replaceFirst('\uFEFF', '');
      await flowsealImportStrategy(
        root: _root,
        name: name.trim(),
        content: content,
      );
      await _refresh();
      if (!mounted) return;
      await _selectStrategy(name.trim());
      if (!mounted) return;
      setState(() {
        _validation = 'Стратегия «${name.trim()}» добавлена.';
      });
      dialogs.showNotifier(
        'Стратегия «${name.trim()}» добавлена в каталог.',
        level: MessageLevel.success,
      );
    });
  }

  Future<void> _selectUserList(String filename) async {
    if (_busy || _testing) return;
    setState(() {
      _selectedUserList = filename;
      _userListEntries = const [];
      _listLoading = true;
    });
    try {
      final entries = await flowsealReadUserList(
        root: _root,
        filename: filename,
      );
      if (!mounted || filename != _selectedUserList) return;
      setState(() => _userListEntries = entries);
    } catch (error) {
      _setError('Не удалось прочитать список: $error');
    } finally {
      if (mounted && filename == _selectedUserList) {
        setState(() => _listLoading = false);
      }
    }
  }

  Future<void> _restartAfterListChange() async {
    final running = _runtime;
    if (running?.running != true) return;
    final strategy = running?.strategy;
    if (strategy == null || strategy.isEmpty) {
      throw Exception(
        'Список сохранён. Остановите и запустите winws.exe вручную, '
        'чтобы применить изменения.',
      );
    }

    final stopped = await flowsealStop(root: _root);
    if (mounted) {
      setState(() => _runtime = stopped);
      _syncStatusPolling();
    }
    final restarted = await flowsealStart(
      root: _root,
      strategy: strategy,
      gameFilterMode: _filterMode,
      gameFilterTcp: _tcpController.text.trim(),
      gameFilterUdp: _udpController.text.trim(),
    );
    if (mounted) {
      setState(() => _runtime = restarted);
      _syncStatusPolling();
    }
  }

  Future<void> _changeIpSetMode(String mode) async {
    if (!_installed || mode == _ipsetMode) return;
    await _withBusy(() async {
      final selected = await flowsealSetIpSetFilter(root: _root, mode: mode);
      if (!mounted) return;
      setState(() {
        _ipsetMode = selected;
        _ipsetUpdateMessage = null;
      });
      await _restartAfterListChange();
    });
  }

  Future<void> _updateIpSet() async {
    if (!_installed) return;
    await _withBusy(() async {
      final result = await flowsealUpdateIpSet(root: _root);
      final mode = await flowsealIpSetStatus(root: _root);
      if (!mounted) return;
      setState(() {
        _ipsetMode = mode;
        _ipsetUpdateMessage = result.changed
            ? 'Список обновлён: ${result.count} записей.'
            : 'Список уже актуален: ${result.count} записей.';
      });
      await _restartAfterListChange();
    });
  }

  Future<void> _addUserListEntry() async {
    if (_busy || _testing) return;
    final entry = _listEntryController.text.trim();
    if (entry.isEmpty || !_installed) return;
    await _withBusy(() async {
      final entries = await flowsealAddUserListEntry(
        root: _root,
        filename: _selectedUserList,
        entry: entry,
      );
      if (!mounted) return;
      setState(() {
        _userListEntries = entries;
        _listEntryController.clear();
      });
      await _restartAfterListChange();
    });
  }

  Future<void> _removeUserListEntry(String entry) async {
    if (_busy || _testing) return;
    await _withBusy(() async {
      final entries = await flowsealRemoveUserListEntry(
        root: _root,
        filename: _selectedUserList,
        entry: entry,
      );
      if (!mounted) return;
      setState(() => _userListEntries = entries);
      await _restartAfterListChange();
    });
  }

  Future<void> _exportSelectedUserList() async {
    if (!_installed) return;
    await _withBusy(() async {
      final content = await flowsealExportUserList(
        root: _root,
        filename: _selectedUserList,
      );
      final baseName = p.basenameWithoutExtension(_selectedUserList);
      await FilePicker.saveFile(
        dialogTitle: 'Экспорт пользовательского списка',
        fileName: '$baseName.txt',
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
    });
  }

  Future<void> _exportUserListsBackup() async {
    if (!_installed) return;
    await _withBusy(() async {
      final content = await flowsealExportUserListsBackup(root: _root);
      await FilePicker.saveFile(
        dialogTitle: 'Создать резервную копию Flowseal',
        fileName: 'flowseal-user-lists.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
    });
  }

  Future<void> _importUserListsBackup() async {
    if (!_installed || _busy || _testing) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null || !mounted) return;
    await _withBusy(() async {
      if ((file.lengthSync() ?? await file.length()) > 8 * 1024 * 1024) {
        throw Exception('Размер резервной копии превышает 8 МиБ.');
      }
      final content = utf8.decode(await file.readAsBytes());
      final backup = await flowsealImportUserListsBackup(
        root: _root,
        content: content,
      );
      final selected = switch (_selectedUserList) {
        'list-general-user.txt' => backup.include,
        'list-exclude-user.txt' => backup.exclude,
        'ipset-exclude-user.txt' => backup.ips,
        _ => const <String>[],
      };
      if (!mounted) return;
      setState(() {
        _userListEntries = selected;
        _validation = 'Резервная копия восстановлена.';
      });
      await _restartAfterListChange();
    });
  }

  Future<void> _importUserList(BuildContext context) async {
    if (!_installed || _busy || _testing) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (file == null || !mounted) return;

    final append = await dialogs.showCommonDialog<bool>(
      child: CommonDialog(
        title: 'Импорт пользовательского списка',
        child: const Text(
          'Добавить записи к существующему списку или полностью заменить его?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Заменить'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (append == null || !mounted) return;

    await _withBusy(() async {
      if ((file.lengthSync() ?? await file.length()) > 2 * 1024 * 1024) {
        throw Exception('Размер списка превышает 2 МиБ.');
      }
      final content = utf8.decode(await file.readAsBytes());
      final imported = content
          .replaceFirst('\uFEFF', '')
          .split(RegExp(r'\r?\n'))
          .where(
            (line) => line.trim().isNotEmpty && !line.trim().startsWith('#'),
          )
          .toList();
      if (imported.isEmpty) {
        throw Exception('В выбранном файле нет записей для импорта.');
      }

      final existing = append
          ? await flowsealReadUserList(root: _root, filename: _selectedUserList)
          : <String>[];
      final saved = await flowsealReplaceUserList(
        root: _root,
        filename: _selectedUserList,
        entries: [...existing, ...imported],
      );
      if (!mounted) return;
      setState(() {
        _userListEntries = saved;
        _validation = append
            ? 'Добавлено записей: ${saved.length - existing.length}. Всего: ${saved.length}.'
            : 'Импортировано записей: ${saved.length}';
      });
      await _restartAfterListChange();
    });
  }

  Future<void> _clearUserList(BuildContext context) async {
    if (!_installed || _busy || _testing || _userListEntries.isEmpty) return;
    final confirmed = await dialogs.showMessage(
      title: 'Очистить список?',
      message: TextSpan(
        text: 'Удалить все записи из «${_flowsealUserLists[_selectedUserList]}»?',
      ),
      confirmText: 'Очистить',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await _withBusy(() async {
      final entries = await flowsealReplaceUserList(
        root: _root,
        filename: _selectedUserList,
        entries: const [],
      );
      if (!mounted) return;
      setState(() {
        _userListEntries = entries;
        _validation = 'Список очищен.';
      });
      await _restartAfterListChange();
    });
  }

  Future<void> _saveGameFilterSettings() async {
    if (!_installed || _busy || _testing) return;
    await _withBusy(() async {
      await flowsealSaveGameFilter(
        root: _root,
        mode: _filterMode,
        tcpRange: _tcpController.text.trim(),
        udpRange: _udpController.text.trim(),
      );
      await _restartAfterListChange();
      if (mounted) {
        setState(() => _validation = 'Параметры Game Filter сохранены.');
      }
    });
  }

  Future<void> _showPreview() async {
    if (_busy || _testing) return;
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
      if (!await flowsealIsElevated()) {
        final handoff = base64Url.encode(
          utf8.encode(
            jsonEncode({
              'strategy': strategy,
              'gameFilterMode': _filterMode,
              'gameFilterTcp': _tcpController.text.trim(),
              'gameFilterUdp': _udpController.text.trim(),
            }),
          ),
        );
        final launched =
            windows?.runas(
              Platform.resolvedExecutable,
              '--flowseal-elevated --flowseal-start=$handoff',
              showWindow: true,
            ) ??
            false;
        if (!launched) {
          throw Exception(
            'Не удалось перезапустить FlClashX с правами администратора. '
            'Запрос UAC был отменён или отклонён.',
          );
        }
        commonPrint.log(
          'Flowseal requested an elevated FlClashX restart through UAC',
        );
        window?.forceExit();
        return;
      }

      final status = await flowsealStart(
        root: _root,
        strategy: strategy,
        gameFilterMode: _filterMode,
        gameFilterTcp: _tcpController.text.trim(),
        gameFilterUdp: _udpController.text.trim(),
      );
      if (mounted) {
        setState(() => _runtime = status);
        _syncStatusPolling();
      }
    });
  }

  Future<void> _stop() async {
    await _withBusy(() async {
      final status = await flowsealStop(root: _root);
      if (mounted) {
        setState(() => _runtime = status);
        _syncStatusPolling();
      }
    });
  }

  String _testTypeLabel(String value) => switch (value) {
    'standard' => 'Сеть и доступность',
    'dpi' => 'Проверка обхода DPI',
    _ => 'Комплексный тест',
  };

  Future<void> _requestElevationForTest() async {
    final launched =
        windows?.runas(
          Platform.resolvedExecutable,
          '--flowseal-elevated',
          showWindow: true,
        ) ??
        false;
    if (!launched) {
      throw Exception(
        'Не удалось перезапустить FlClashX с правами администратора. '
        'Проверьте запрос UAC.',
      );
    }
    commonPrint.log('Flowseal strategy test requested elevated FlClashX');
    window?.forceExit();
  }

  Future<void> _runStrategyTests() async {
    if (!_installed || _testing || _busy) return;
    if (_running) {
      dialogs.showNotifier(
        'Перед автотестом остановите текущий winws.exe.',
        level: MessageLevel.warning,
      );
      return;
    }
    if (!_elevated) {
      await _requestElevationForTest();
      return;
    }

    setState(() {
      _testing = true;
      _testWasCancelled = false;
      _testProgress = null;
      _testResults = const [];
      _error = null;
    });
    await _testSubscription?.cancel();
    _testSubscription = flowsealStrategyTestEvents().listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _testProgress = event;
          if (event.message.toLowerCase().contains('остановлена пользователем')) {
            _testWasCancelled = true;
          }
        });
      },
      onError: (Object error) {
        if (mounted) _setError('Ошибка потока автотеста: ' + error.toString());
      },
    );

    try {
      final results = await flowsealTestStrategies(
        root: _root,
        testType: _testType,
        gameFilterMode: _filterMode,
        gameFilterTcp: _tcpController.text.trim(),
        gameFilterUdp: _udpController.text.trim(),
      );
      if (!mounted) return;
      final wasCancelled = _testWasCancelled;
      FlowsealStrategyTestResult? best;
      for (final result in results) {
        if (result.score > 0) {
          best = result;
          break;
        }
      }
      setState(() {
        _testResults = results;
        if (best != null) {
          _preview = null;
          _validation = 'Автотест выбрал «' + best.strategy + '».';
        }
      });
      if (best != null) await _selectStrategy(best.strategy);
      if (wasCancelled) {
        dialogs.showNotifier(
          best == null
              ? 'Проверка остановлена. Завершённых успешных результатов нет.'
              : 'Проверка остановлена. Лучший результат среди проверенных: ' +
                    best.strategy,
          level: MessageLevel.info,
        );
      } else if (best != null) {
        dialogs.showNotifier(
          'Лучшая стратегия: ' + best.strategy + ' · HTTP ' +
              best.httpOk.toString() + '/' +
              (best.httpOk + best.httpError).toString(),
          level: MessageLevel.success,
        );
      } else {
        dialogs.showNotifier(
          'Все стратегии завершились с ошибками. Проверьте каталог и подключение.',
          level: MessageLevel.warning,
        );
      }
      await _refresh();
    } catch (error) {
      if (mounted) _setError('Автотест не выполнен: ' + error.toString());
    } finally {
      await _testSubscription?.cancel();
      _testSubscription = null;
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _cancelStrategyTests() async {
    if (!_testing) return;
    await flowsealCancelStrategyTests();
  }

  void _handleListSearch(String query) {
    setState(() => _listQuery = query.trim().toLowerCase());
  }

  Future<void> _openLogFolder() async {
    final logPath = _runtime?.logPath;
    if (logPath == null || logPath.isEmpty) return;
    await system.openDirectory(p.dirname(logPath));
  }

  Future<void> _promptAddUserListEntry() async {
    final value = await dialogs.showCommonDialog<String>(
      child: InputDialog(
        title: 'Добавить запись',
        value: '',
        hintText: _selectedUserList == 'ipset-exclude-user.txt'
            ? '192.0.2.0/24'
            : 'example.com',
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return 'Введите домен или IP-адрес.';
          }
          return null;
        },
      ),
    );
    if (value == null || !mounted) return;
    _listEntryController.text = value.trim();
    await _addUserListEntry();
  }

  Widget _buildTestResult(BuildContext context, FlowsealStrategyTestResult result) {
    final colorScheme = context.colorScheme;
    final isSelected = result.strategy == _selectedStrategy;
    final statusColor = switch (result.status) {
      'success' => colorScheme.primary,
      'partial' => colorScheme.tertiary,
      _ => colorScheme.error,
    };
    final total = result.httpOk + result.httpError;
    final ping = result.avgPingMs > 0
        ? result.avgPingMs.toString() + ' мс'
        : '—';
    return ListItem(
      leading: Icon(
        result.status == 'success'
            ? Icons.check_circle_outline
            : result.status == 'partial'
                ? Icons.warning_amber_rounded
                : Icons.error_outline,
        color: statusColor,
      ),
      title: Text(
        result.strategy,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isSelected ? TextStyle(color: colorScheme.primary) : null,
      ),
      subtitle: Text(
        'HTTP ' + result.httpOk.toString() + '/' + total.toString() +
        ' · TCP ' + ping + ' · Score ' + result.score.toString(),
      ),
      trailing: isSelected
          ? Icon(Icons.radio_button_checked, color: colorScheme.primary)
          : const Icon(Icons.radio_button_unchecked),
      onTap: _busy || _testing
          ? null
          : () => unawaited(_selectStrategy(result.strategy)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final installation = _installation;
    final filteredEntries = _userListEntries
        .where((entry) => entry.toLowerCase().contains(_listQuery))
        .toList();
    final visibleEntries = filteredEntries.take(200).toList();
    final filteredStrategies = _strategies
        .where((strategy) => strategy.toLowerCase().contains(_listQuery))
        .toList();
    final progress = _testProgress;
    final progressValue = progress == null || progress.total == BigInt.zero
        ? null
        : (progress.current.toDouble() / progress.total.toDouble())
            .clamp(0.0, 1.0);

    return CommonScaffold(
      title: 'Zapret / Flowseal',
      isLoading: _busy || _testing,
      searchState: _installed
          ? AppBarSearchState(onSearch: _handleListSearch)
          : null,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.importFile,
          tooltip: 'Импортировать BAT',
          onPressed: _installed && !_busy && !_testing
              ? _importStrategy
              : null,
        ),
        IconButtonData(
          glyph: AppGlyphs.sync,
          tooltip: _testing ? 'Проверка стратегий выполняется' : 'Автотест стратегий',
          isLoading: _testing,
          onPressed: _installed && !_busy && !_testing
              ? _runStrategyTests
              : null,
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: 'Установка Flowseal',
            items: [
              ListItem.input(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Каталог Flowseal'),
                subtitle: Text(_root.isEmpty ? 'Не выбран' : _root),
                dialogTitle: 'Каталог Flowseal',
                value: _root,
                maxLength: 512,
                keyboardType: TextInputType.text,
                onChanged: (value) {
                  if (value == null || value.trim().isEmpty) return;
                  _rootController.text = value.trim();
                  unawaited(_saveRoot());
                },
              ),
              ListItem(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Выбрать папку Flowseal'),
                subtitle: const Text('Указать существующий каталог или место установки'),
                onTap: _busy || _testing ? null : _pickRoot,
              ),
              ListItem(
                leading: Icon(
                  installation?.installed == true
                      ? Icons.verified_outlined
                      : Icons.info_outline,
                  color: installation?.installed == true
                      ? context.colorScheme.primary
                      : context.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  _root.isEmpty
                      ? 'Каталог не выбран'
                      : installation?.installed == true
                          ? 'Flowseal найден · ' + installation!.version
                          : 'Flowseal не обнаружен',
                ),
                subtitle: installation?.installed == true
                    ? Text(installation!.executable)
                    : const Text('Нужны winws.exe, WinDivert и каталог стратегий'),
              ),
              ListItem(
                leading: const Icon(Icons.download_outlined),
                title: Text(
                  _installed ? 'Переустановить / обновить Flowseal' : 'Установить Flowseal',
                ),
                onTap: _busy || _testing || _root.isEmpty
                    ? null
                    : _installOrUpdate,
              ),
              ListItem(
                leading: const Icon(Icons.fact_check_outlined),
                title: const Text('Проверить установку'),
                subtitle: const Text('Проверка файлов и каталога стратегий'),
                onTap: _busy || _testing || !_installed ? null : _validate,
              ),
              if (_validation != null)
                ListItem(
                  leading: Icon(
                    Icons.check_circle_outline,
                    color: context.colorScheme.primary,
                  ),
                  title: Text(_validation!),
                ),
            ],
          ),
          generateSection(
            title: 'Управление winws.exe',
            items: [
              ListItem(
                leading: Icon(
                  _running ? Icons.play_circle_fill : Icons.stop_circle_outlined,
                  color: _running
                      ? context.colorScheme.primary
                      : context.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  _running
                      ? 'Запущен · PID ' + (_runtime?.pid?.toString() ?? '—')
                      : 'Остановлен',
                ),
                subtitle: Text(
                  _runtime?.strategy == null
                      ? (_elevated
                          ? 'Права администратора: есть'
                          : 'Права администратора: нет')
                      : 'Стратегия: ' + _runtime!.strategy!,
                ),
              ),
              if (!_elevated)
                ListItem(
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: const Text('Перезапустить FlClashX с правами администратора'),
                  subtitle: const Text('Нужно для запуска winws.exe и автотестирования'),
                  onTap: _busy || _testing ? null : _requestElevationForTest,
                ),
              ListItem(
                leading: const Icon(Icons.play_arrow_rounded),
                title: Text(_elevated ? 'Запустить выбранную стратегию' : 'Запустить с UAC'),
                subtitle: Text(_selectedStrategy ?? 'Сначала выберите стратегию'),
                onTap: _busy || _testing || !_installed || _running ||
                        _selectedStrategy == null
                    ? null
                    : _start,
              ),
              ListItem(
                leading: const Icon(Icons.stop_rounded),
                title: const Text('Остановить winws.exe'),
                onTap: _busy || _testing || !_running ? null : _stop,
              ),
              ListItem(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Открыть папку логов'),
                subtitle: Text(_runtime?.logPath ?? ''),
                onTap: _runtime == null || _runtime!.logPath.isEmpty
                    ? null
                    : _openLogFolder,
              ),
            ],
          ),
          if (_error != null)
            generateSection(
              title: 'Ошибка',
              items: [
                ListItem(
                  leading: Icon(Icons.error_outline, color: context.colorScheme.error),
                  title: Text(
                    _error!,
                    style: TextStyle(color: context.colorScheme.error),
                  ),
                ),
              ],
            ),
          if (_installed) ...[
            generateSection(
              title: 'Стратегии Flowseal',
              items: [
                ListItem(
                  leading: const Icon(Icons.tune),
                  title: Text(
                    _selectedStrategy == null
                        ? 'Стратегия не выбрана'
                        : 'Выбрана: ${_selectedStrategy!}',
                  ),
                  subtitle: Text(
                    'Доступно стратегий: ${_strategies.length}. '
                    'Показываются готовые и импортированные BAT.',
                  ),
                ),
                if (_strategies.isEmpty)
                  const ListItem(
                    title: Text('Готовые стратегии не найдены'),
                    subtitle: Text('Проверьте установку Flowseal или импортируйте BAT-файл'),
                  )
                else if (filteredStrategies.isEmpty)
                  const ListItem(
                    title: Text('Совпадений не найдено'),
                    subtitle: Text('Измените поисковый запрос в верхней панели'),
                  )
                else
                  for (final strategy in filteredStrategies)
                    ListItem(
                      leading: Icon(
                        strategy == _selectedStrategy
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: strategy == _selectedStrategy
                            ? context.colorScheme.primary
                            : context.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        strategy,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        strategy == _selectedStrategy
                            ? 'Выбрана для запуска'
                            : 'Нажмите, чтобы выбрать',
                      ),
                      onTap: _busy || _testing
                          ? null
                          : () => unawaited(_selectStrategy(strategy)),
                    ),
                ListItem.options<String>(
                  leading: const Icon(Icons.sports_esports_outlined),
                  title: const Text('Game Filter'),
                  subtitle: const Text('Фильтрация игровых TCP/UDP-портов'),
                  options: const ['none', 'all', 'tcp', 'udp'],
                  value: _filterMode,
                  textBuilder: (mode) => switch (mode) {
                    'all' => 'TCP + UDP',
                    'tcp' => 'Только TCP',
                    'udp' => 'Только UDP',
                    _ => 'Отключён',
                  },
                  onChanged: (mode) {
                    if (_busy || _testing) return;
                    setState(() {
                      _filterMode = mode;
                      _preview = null;
                    });
                    unawaited(_saveGameFilterSettings());
                  },
                ),
                ListItem.input(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('TCP-порты'),
                  subtitle: Text(_tcpController.text),
                  dialogTitle: 'Диапазоны TCP-портов',
                  value: _tcpController.text,
                  maxLength: 64,
                  keyboardType: TextInputType.text,
                  onChanged: (value) {
                    if (value == null || _busy || _testing) return;
                    _tcpController.text = value;
                    setState(() => _preview = null);
                    unawaited(_saveGameFilterSettings());
                  },
                ),
                ListItem.input(
                  leading: const Icon(Icons.swap_vert),
                  title: const Text('UDP-порты'),
                  subtitle: Text(_udpController.text),
                  dialogTitle: 'Диапазоны UDP-портов',
                  value: _udpController.text,
                  maxLength: 64,
                  keyboardType: TextInputType.text,
                  onChanged: (value) {
                    if (value == null || _busy || _testing) return;
                    _udpController.text = value;
                    setState(() => _preview = null);
                    unawaited(_saveGameFilterSettings());
                  },
                ),
                ListItem(
                  leading: const Icon(Icons.code),
                  title: const Text('Просмотр аргументов winws.exe'),
                  subtitle: const Text('Посмотреть, что будет передано выбранной стратегии'),
                  onTap: _busy || _testing || _selectedStrategy == null
                      ? null
                      : _showPreview,
                ),
                if (_preview != null)
                  ListItem(
                    leading: const Icon(Icons.terminal),
                    title: const Text('Аргументы стратегии'),
                    subtitle: SelectableText(
                      _preview!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'JetBrainsMono',
                            color: context.colorScheme.onSurface,
                          ),
                    ),
                  ),
                ListItem(
                  leading: const Icon(Icons.file_open_outlined),
                  title: const Text('Добавить стратегию из BAT-файла'),
                  subtitle: const Text('Файл будет разобран и добавлен в список'),
                  onTap: _busy || _testing ? null : _importStrategy,
                ),
              ],
              footer: 'BAT используется только как источник аргументов winws.exe. '
                  'Сценарии BAT/CMD не исполняются.',
            ),
            generateSection(
              title: 'Автоматический подбор стратегии',
              items: [
                ListItem.options<String>(
                  leading: const Icon(Icons.speed),
                  title: const Text('Режим проверки'),
                  options: const ['standard', 'dpi', 'combined'],
                  value: _testType,
                  textBuilder: _testTypeLabel,
                  onChanged: (value) => setState(() => _testType = value),
                ),
                ListItem(
                  leading: Icon(
                    _testing ? Icons.sync : Icons.play_circle_outline,
                    color: _testing
                        ? context.colorScheme.primary
                        : context.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(_testing ? 'Проверка выполняется' : 'Запустить автотест всех стратегий'),
                  subtitle: Text(
                    _testing
                        ? (progress?.message ?? 'Подготовка...')
                        : 'winws.exe запускается по очереди для каждой стратегии',
                  ),
                  onTap: _testing || _busy ? null : _runStrategyTests,
                ),
                if (_testing) ...[
                  ListItem(
                    leading: const Icon(Icons.stop_circle_outlined),
                    title: const Text('Остановить проверку'),
                    onTap: _cancelStrategyTests,
                  ),
                  if (progressValue != null)
                    ListItem(
                      title: LinearProgressIndicator(value: progressValue),
                      subtitle: Text(
                        progress!.current.toString() + ' / ' +
                        progress.total.toString() +
                        (progress.strategy.isEmpty ? '' : ' · ' + progress.strategy),
                      ),
                    ),
                ],
                if (!_testing && _testResults.isNotEmpty)
                  ListItem(
                    leading: Icon(Icons.emoji_events_outlined, color: context.colorScheme.primary),
                    title: Text('Лучшая: ' + _testResults.first.strategy),
                    subtitle: Text(
                      'HTTP ' + _testResults.first.httpOk.toString() + '/' +
                      (_testResults.first.httpOk + _testResults.first.httpError).toString() +
                      ' · Score ' + _testResults.first.score.toString(),
                    ),
                    trailing: const Icon(Icons.check_circle_outline),
                  ),
                for (final result in _testResults)
                  _buildTestResult(context, result),
              ],
              footer: 'Комплексный режим проверяет обычные HTTP/TCP-соединения и DPI-запросы. '
                  'Лучшая доступная стратегия автоматически выбирается, но не запускается без твоего действия.',
            ),
            generateSection(
              title: 'IPSet Filter',
              items: [
                ListItem.options<String>(
                  leading: const Icon(Icons.filter_alt_outlined),
                  title: const Text('Режим IPSet'),
                  options: const ['none', 'any', 'loaded'],
                  value: _ipsetMode,
                  textBuilder: (mode) => switch (mode) {
                    'none' => 'Отключён',
                    'loaded' => 'Использовать список IP',
                    _ => 'Без фильтрации',
                  },
                  onChanged: (mode) {
                    if (_busy || _testing) return;
                    unawaited(_changeIpSetMode(mode));
                  },
                ),
                ListItem(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Обновить IPSet'),
                  subtitle: Text(_ipsetUpdateMessage ?? 'Загрузить актуальный список Flowseal'),
                  onTap: _busy || _testing ? null : _updateIpSet,
                ),
              ],
              footer: 'При смене режима работающая стратегия перезапускается.',
            ),
            generateSection(
              title: 'Пользовательские списки',
              items: [
                ListItem.options<String>(
                  leading: const Icon(Icons.list_alt),
                  title: const Text('Тип списка'),
                  options: _flowsealUserLists.keys.toList(),
                  value: _selectedUserList,
                  textBuilder: (filename) => _flowsealUserLists[filename] ?? filename,
                  onChanged: (filename) {
                    if (_busy || _testing) return;
                    unawaited(_selectUserList(filename));
                  },
                ),
                ListItem(
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('Добавить запись'),
                  subtitle: Text(
                    _selectedUserList == 'ipset-exclude-user.txt'
                        ? 'IPv4 или CIDR'
                        : 'Доменное имя',
                  ),
                  onTap: _busy || _testing ? null : _promptAddUserListEntry,
                ),
                ListItem(
                  leading: const Icon(Icons.file_upload_outlined),
                  title: const Text('Импортировать TXT'),
                  onTap: _busy || _testing ? null : () => _importUserList(context),
                ),
                ListItem(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Экспортировать выбранный список'),
                  onTap: _busy || _testing ? null : _exportSelectedUserList,
                ),
                ListItem(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('Очистить выбранный список'),
                  onTap: _busy || _testing || _userListEntries.isEmpty
                      ? null
                      : () => _clearUserList(context),
                ),
                ListItem(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Создать резервную копию всех списков'),
                  onTap: _busy || _testing ? null : _exportUserListsBackup,
                ),
                ListItem(
                  leading: const Icon(Icons.settings_backup_restore_outlined),
                  title: const Text('Восстановить резервную копию'),
                  onTap: _busy || _testing ? null : _importUserListsBackup,
                ),
                ListItem(
                  leading: const Icon(Icons.search),
                  title: Text('Записей: ' + _userListEntries.length.toString()),
                  subtitle: Text(
                    filteredEntries.isEmpty
                        ? 'Список пуст или совпадений нет'
                        : 'Показано ' + visibleEntries.length.toString() +
                            ' из ' + filteredEntries.length.toString(),
                  ),
                ),
                for (final entry in visibleEntries)
                  ListItem(
                    title: Text(entry),
                    trailing: IconButton(
                      tooltip: 'Удалить запись',
                      onPressed: _busy || _testing
                          ? null
                          : () => _removeUserListEntry(entry),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
              ],
              footer: 'Списки хранятся в каталоге Flowseal. При работающем winws.exe '
                  'изменения применяются перезапуском процесса.',
            ),
          ],
        ],
      ),
    );
  }

}
