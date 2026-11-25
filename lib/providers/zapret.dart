import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/zapret_diagnostics.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final zapretControllerProvider =
    NotifierProvider<ZapretController, ZapretState>(ZapretController.new);

enum ZapretMode { strictSplit, fullBypass }

class ZapretState {
  final bool available;
  final bool running;
  final bool busy;
  final bool debugLogs;
  final bool startWithMihomo;
  final bool watchdog;
  final bool autoFallback;
  final String? testProgress;
  final List<ZapretTrial> trials;
  final int? pid;
  final Duration elapsed;
  final int cleanedProcesses;
  final String? activeStrategyId;
  final String? activeEngine;
  final String? activeMode;
  final List<String> winDivertFilters;
  final List<String> processingLists;
  final List<HelperZapretStrategy> strategies;
  final String selectedStrategyId;
  final ZapretMode mode;
  final String? error;

  const ZapretState({
    this.available = false,
    this.running = false,
    this.busy = false,
    this.debugLogs = false,
    this.startWithMihomo = false,
    this.watchdog = true,
    this.autoFallback = false,
    this.testProgress,
    this.trials = const [],
    this.pid,
    this.elapsed = Duration.zero,
    this.cleanedProcesses = 0,
    this.activeStrategyId,
    this.activeEngine,
    this.activeMode,
    this.winDivertFilters = const [],
    this.processingLists = const [],
    this.strategies = const [],
    this.selectedStrategyId = ZapretController.defaultStrategyId,
    this.mode = ZapretMode.fullBypass,
    this.error,
  });

  ZapretState copyWith({
    bool? available,
    bool? running,
    bool? busy,
    bool? debugLogs,
    bool? startWithMihomo,
    bool? watchdog,
    bool? autoFallback,
    String? testProgress,
    bool clearTestProgress = false,
    List<ZapretTrial>? trials,
    int? pid,
    Duration? elapsed,
    bool clearPid = false,
    int? cleanedProcesses,
    String? activeStrategyId,
    bool clearActiveStrategy = false,
    String? activeEngine,
    bool clearActiveEngine = false,
    String? activeMode,
    bool clearActiveMode = false,
    List<String>? winDivertFilters,
    List<String>? processingLists,
    List<HelperZapretStrategy>? strategies,
    String? selectedStrategyId,
    ZapretMode? mode,
    String? error,
    bool clearError = false,
  }) {
    return ZapretState(
      available: available ?? this.available,
      running: running ?? this.running,
      busy: busy ?? this.busy,
      debugLogs: debugLogs ?? this.debugLogs,
      startWithMihomo: startWithMihomo ?? this.startWithMihomo,
      watchdog: watchdog ?? this.watchdog,
      autoFallback: autoFallback ?? this.autoFallback,
      testProgress: clearTestProgress ? null : testProgress ?? this.testProgress,
      trials: trials ?? this.trials,
      pid: clearPid ? null : pid ?? this.pid,
      elapsed: elapsed ?? this.elapsed,
      cleanedProcesses: cleanedProcesses ?? this.cleanedProcesses,
      activeStrategyId: clearActiveStrategy
          ? null
          : activeStrategyId ?? this.activeStrategyId,
      activeEngine: clearActiveEngine ? null : activeEngine ?? this.activeEngine,
      activeMode: clearActiveMode ? null : activeMode ?? this.activeMode,
      winDivertFilters: winDivertFilters ?? this.winDivertFilters,
      processingLists: processingLists ?? this.processingLists,
      strategies: strategies ?? this.strategies,
      selectedStrategyId: selectedStrategyId ?? this.selectedStrategyId,
      mode: mode ?? this.mode,
      error: clearError ? null : error ?? this.error,
    );
  }

  bool get supportsSplitMode {
    for (final strategy in strategies) {
      if (strategy.id == selectedStrategyId) return strategy.supportsSplitMode;
    }
    return false;
  }
}

class ZapretTrial {
  const ZapretTrial(this.id, this.mode, this.score, this.delay, {this.confirmed = false});
  final String id;
  final ZapretMode mode;
  final int score;
  final int delay;
  final bool confirmed;
}

class ZapretController extends Notifier<ZapretState> {
  static const defaultStrategyId = 'flowseal-alt';
  static const _selectedStrategyPreferenceKey = 'zapret.strategyId';
  static const _modePreferenceKey = 'zapret.mode';
  static const _debugPreferenceKey = 'zapret.debugLogs';
  static const _linkedStartPreferenceKey = 'zapret.startWithMihomo';
  static const _pollInterval = Duration(seconds: 3);
  static const _readinessTimeout = Duration(seconds: 3);

  final HelperClient _client = helperClient;
  Timer? _poller;
  Timer? _clock;
  final Stopwatch _uptime = Stopwatch();
  int? _observedPid;
  Duration _baseUptime = Duration.zero;

  Duration _observeProcess(bool running, int? pid, [int uptimeMs = 0]) {
    if (!running) {
      _uptime.stop();
      _uptime.reset();
      _observedPid = null;
      _baseUptime = Duration.zero;
    } else if (!_uptime.isRunning || pid != _observedPid || uptimeMs > 0) {
      _baseUptime = Duration(milliseconds: uptimeMs);
      _uptime.reset();
      _uptime.start();
      _observedPid = pid;
    }
    return _baseUptime + _uptime.elapsed;
  }
  var _refreshing = false;
  bool _cancelTrial = false;
  int _failedChecks = 0;
  DateTime? _fallbackAfter;
  bool _checkingFallback = false;

  @override
  ZapretState build() {
    ref.onDispose(() {
      _poller?.cancel();
      _clock?.cancel();
    });
    if (Platform.isWindows) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (ref.mounted && state.running) {
          state = state.copyWith(elapsed: _baseUptime + _uptime.elapsed);
        }
      });
      scheduleMicrotask(() {
        if (!ref.mounted) return;
        unawaited(loadStrategies());
        unawaited(refresh());
      });
      _poller = Timer.periodic(_pollInterval, (_) {
        if (ref.mounted) unawaited(refresh());
      });
    }
    return const ZapretState();
  }

  /// Loads the same pinned strategy catalog as zapret2-gui. The selected
  /// strategy is persisted independently of the running profile.
  Future<void> loadStrategies() async {
    if (!Platform.isWindows || !ref.mounted) return;
    try {
      final strategies = await _client.zapretStrategies();
      final preferences = await SharedPreferences.getInstance();
      final savedId = preferences.getString(_selectedStrategyPreferenceKey);
      final savedMode = preferences.getString(_modePreferenceKey);
      final selectedMode = ZapretMode.values.firstWhere(
        (item) => item.name == savedMode,
        orElse: () => ZapretMode.fullBypass,
      );
      final currentId = state.selectedStrategyId;
      final selectedId = strategies.isEmpty
          ? currentId
          : strategies.any((item) => item.id == savedId)
              ? savedId!
              : strategies.any((item) => item.id == currentId)
                  ? currentId
                  : strategies.any((item) => item.id == defaultStrategyId)
                      ? defaultStrategyId
                      : strategies.first.id;
      if (!ref.mounted) return;
      state = state.copyWith(
        available: strategies.isNotEmpty,
        strategies: strategies,
        selectedStrategyId: selectedId,
        mode: selectedMode,
        debugLogs: preferences.getBool(_debugPreferenceKey) ?? false,
        startWithMihomo: preferences.getBool(_linkedStartPreferenceKey) ?? false,
        watchdog: preferences.getBool('zapret.watchdog') ?? true,
        autoFallback: preferences.getBool('zapret.autoFallback') ?? false,
        clearError: strategies.isNotEmpty,
      );
      if (strategies.isNotEmpty && savedId != selectedId) {
        await preferences.setString(_selectedStrategyPreferenceKey, selectedId);
      }
      if (savedMode != selectedMode.name) {
        await preferences.setString(_modePreferenceKey, selectedMode.name);
      }
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        available: false,
        error: _errorMessage(error),
      );
    }
  }

  Future<void> selectStrategy(String strategyId) async {
    if (state.busy) return;
    if (!state.strategies.any((item) => item.id == strategyId)) {
      throw ArgumentError.value(strategyId, 'strategyId', 'Unknown Zapret strategy');
    }
    state = state.copyWith(selectedStrategyId: strategyId, clearError: true);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_selectedStrategyPreferenceKey, strategyId);
  }

  Future<void> setMode(ZapretMode mode) async {
    if (state.busy || !state.supportsSplitMode) return;
    state = state.copyWith(mode: mode, clearError: true);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_modePreferenceKey, mode.name);
  }

  Future<void> setStartWithMihomo(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_linkedStartPreferenceKey, enabled);
    if (ref.mounted) state = state.copyWith(startWithMihomo: enabled);
  }

  /// Called once after an actual new Mihomo run starts. Never follows stop.
  Future<void> startAlongsideMihomo() async {
    if (!Platform.isWindows || !ref.mounted) return;
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_linkedStartPreferenceKey) != true || !ref.mounted) return;
    if (state.strategies.isEmpty) await loadStrategies();
    await refresh();
    if (ref.mounted && state.available && !state.busy && !state.running) {
      await setEnabled(true);
    }
  }

  Future<void> setDebugLogs(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_debugPreferenceKey, enabled);
    if (ref.mounted) state = state.copyWith(debugLogs: enabled);
  }

  Future<void> refresh() async {
    if (!Platform.isWindows || _refreshing || state.busy) return;
    _refreshing = true;
    try {
      final response = await _client.zapretStatus();
      if (!ref.mounted || state.busy) return;
      state = state.copyWith(
        available: state.strategies.isNotEmpty,
        running: response.running,
        elapsed: _observeProcess(response.running, response.pid, response.uptimeMs),
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        activeStrategyId: response.strategyId,
        activeEngine: response.engine,
        clearActiveStrategy: !response.running,
        clearActiveEngine: !response.running,
        activeMode: response.mode,
        clearActiveMode: !response.running,
        winDivertFilters: response.winDivertFilters,
        processingLists: response.processingLists,
        clearError: state.strategies.isNotEmpty,
      );
    } on HelperException catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        available: error.code != 'zapretUnsupported',
        running: false,
        elapsed: _observeProcess(false, null),
        clearPid: true,
        clearActiveStrategy: true,
        clearActiveEngine: true,
        clearActiveMode: true,
        winDivertFilters: const [],
        processingLists: const [],
        error: error.message,
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        running: false,
        elapsed: _observeProcess(false, null),
        clearPid: true,
        clearActiveStrategy: true,
        clearActiveEngine: true,
        clearActiveMode: true,
        winDivertFilters: const [],
        processingLists: const [],
        error: error.toString(),
      );
    } finally {
      _refreshing = false;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (!Platform.isWindows || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _requireHelper();
      final response = enabled
          ? await _client.startZapret(
              strategyId: state.selectedStrategyId,
              debug: state.debugLogs,
              watchdog: state.watchdog,
              mode: (state.supportsSplitMode ? state.mode : ZapretMode.fullBypass).name,
            )
          : await _client.stopZapret();
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        elapsed: _observeProcess(response.running, response.pid, response.uptimeMs),
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        activeStrategyId: response.strategyId,
        activeEngine: response.engine,
        clearActiveStrategy: !response.running,
        clearActiveEngine: !response.running,
        activeMode: response.mode,
        clearActiveMode: !response.running,
        winDivertFilters: response.winDivertFilters,
        processingLists: response.processingLists,
      );
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(error: _errorMessage(error));
      }
      rethrow;
    } finally {
      if (ref.mounted) {
        state = state.copyWith(busy: false);
      }
    }
  }

  /// Restart also runs the upstream GUI's orphaned-process cleanup in Helper
  /// before it starts the selected winws.exe or winws2.exe profile.
  Future<void> restart() async {
    if (!Platform.isWindows || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _requireHelper();
      final response = await _client.restartZapret(
        strategyId: state.selectedStrategyId,
              debug: state.debugLogs,
              watchdog: state.watchdog,
        mode: (state.supportsSplitMode ? state.mode : ZapretMode.fullBypass).name,
      );
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        elapsed: _observeProcess(response.running, response.pid, response.uptimeMs),
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        activeStrategyId: response.strategyId,
        activeEngine: response.engine,
        clearActiveStrategy: !response.running,
        clearActiveEngine: !response.running,
        activeMode: response.mode,
        clearActiveMode: !response.running,
        winDivertFilters: response.winDivertFilters,
        processingLists: response.processingLists,
      );
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(error: _errorMessage(error));
      }
      rethrow;
    } finally {
      if (ref.mounted) {
        state = state.copyWith(busy: false);
      }
    }
  }

  Future<void> setWatchdog(bool value) async {
    if (state.busy) return;
    if (state.available) await _client.setZapretWatchdog(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('zapret.watchdog', value);
    if (ref.mounted) state = state.copyWith(watchdog: value);
  }

  Future<void> setAutoFallback(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('zapret.autoFallback', value);
    _failedChecks = 0;
    if (ref.mounted) state = state.copyWith(autoFallback: value);
  }

  void cancelTrials() => _cancelTrial = true;

  Future<int?> _screen() async {
    final results = await measureZapretTargets(ref, [ZapretProbeTarget.youtube]);
    final result = results[ZapretProbeTarget.youtube];
    return result?.message == 'DIRECT · HTTP 2xx' ? result?.latencyMs : null;
  }

  Future<ZapretTrial> _verify(String id, ZapretMode mode) async {
    const targets = [ZapretProbeTarget.youtube, ZapretProbeTarget.discordGateway, ZapretProbeTarget.discordVoice];
    final items = await measureZapretTargets(ref, targets);
    final good = items.values.where((item) => item.message == 'DIRECT · HTTP 2xx' && item.latencyMs != null).toList();
    final score = good.fold<int>(0, (sum, item) => sum + (item.latencyMs! <= 450 ? 2 : 1));
    final delay = good.fold<int>(0, (sum, item) => sum + item.latencyMs!);
    final status = await _client.zapretStatus();
    return ZapretTrial(id, mode, status.running && status.strategyId == id ? score : 0,
        delay, confirmed: status.running && status.strategyId == id && good.length == targets.length);
  }

  /// Two-phase adaptation of Zapret2 GUI: screen all installed profiles, then
  /// run service checks on the eight best screens. Do not persist test choices.
  Future<void> testStrategies() async {
    if (!Platform.isWindows || state.busy || state.strategies.isEmpty ||
        ref.read(coreStatusProvider) != CoreStatus.connected) return;
    final original = await _client.zapretStatus();
    if (state.busy || !ref.mounted) return;
    final strategies = state.strategies.toList();
    final selectedMode = state.mode;
    _cancelTrial = false;
    state = state.copyWith(busy: true, trials: const [], testProgress: 'Подготовка');
    final screened = <ZapretTrial>[];
    final results = <ZapretTrial>[];
    String? failure;
    try {
      for (var i = 0; i < strategies.length && !_cancelTrial; i++) {
        final item = strategies[i];
        final mode = item.supportsSplitMode ? selectedMode : ZapretMode.fullBypass;
        state = state.copyWith(testProgress: 'YouTube ${i + 1}/${strategies.length}: ${item.name}');
        try {
          await _client.restartZapret(strategyId: item.id, mode: mode.name, watchdog: false);
          await Future<void>.delayed(const Duration(seconds: 1));
          final delay = await _screen();
          final status = await _client.zapretStatus();
          if (delay != null && delay > 0 && status.running && status.strategyId == item.id) {
            screened.add(ZapretTrial(item.id, mode, delay <= 450 ? 2 : 1, delay));
          }
        } catch (_) {
          // Unavailable candidate; continue without replacing the original selection.
        }
      }
      screened.sort((a, b) {
        final score = b.score.compareTo(a.score);
        return score != 0 ? score : a.delay.compareTo(b.delay);
      });
      final finalists = screened.take(8).toList();
      for (var i = 0; i < finalists.length && !_cancelTrial; i++) {
        final item = finalists[i];
        state = state.copyWith(testProgress: 'Проверка ${i + 1}/${finalists.length}: ${item.id}');
        try {
          await _client.restartZapret(strategyId: item.id, mode: item.mode.name, watchdog: false);
          await Future<void>.delayed(const Duration(seconds: 1));
          results.add(await _verify(item.id, item.mode));
        } catch (_) {
          results.add(ZapretTrial(item.id, item.mode, 0, 0));
        }
      }
      results.sort((a, b) {
        final verified = (b.confirmed ? 1 : 0).compareTo(a.confirmed ? 1 : 0);
        if (verified != 0) return verified;
        final score = b.score.compareTo(a.score);
        return score != 0 ? score : a.delay.compareTo(b.delay);
      });
    } catch (error) {
      failure = _errorMessage(error);
    } finally {
      try {
        if (original.running && original.strategyId != null) {
          await _client.restartZapret(strategyId: original.strategyId!,
              mode: original.mode ?? 'fullBypass', debug: state.debugLogs, watchdog: state.watchdog);
        } else {
          await _client.stopZapret();
        }
      } catch (error) {
        failure = 'Не удалось восстановить исходную стратегию: $error';
      }
      if (ref.mounted) {
        state = state.copyWith(busy: false, clearTestProgress: true,
            trials: _cancelTrial ? const [] : List.unmodifiable(results), error: failure);
        await refresh();
      }
    }
  }

  Future<void> applyTrial(ZapretTrial trial) async {
    if (state.busy || !trial.confirmed) return;
    await selectStrategy(trial.id);
    await setMode(trial.mode);
    await restart();
  }

  Future<void> checkFallback() async {
    if (_checkingFallback || state.busy || !state.running || !state.autoFallback ||
        state.activeStrategyId == null ||
        ref.read(coreStatusProvider) != CoreStatus.connected ||
        (_fallbackAfter != null && DateTime.now().isBefore(_fallbackAfter!))) return;
    final backup = state.trials.where((trial) =>
        trial.confirmed && trial.id != state.activeStrategyId).firstOrNull;
    if (backup == null) return;
    _checkingFallback = true;
    try {
      final originalId = state.activeStrategyId!;
      final originalMode = state.activeMode == 'strictSplit' ? ZapretMode.strictSplit : ZapretMode.fullBypass;
      final current = await _verify(originalId, originalMode);
      if (state.busy || state.activeStrategyId != originalId || !state.running) return;
      if (!state.autoFallback || ref.read(coreStatusProvider) != CoreStatus.connected) return;
      if (current.confirmed) {
        _failedChecks = 0;
        return;
      }
      if (++_failedChecks < 3) return;
      _failedChecks = 0;
      _fallbackAfter = DateTime.now().add(const Duration(minutes: 5));
      state = state.copyWith(busy: true);
      var accepted = false;
      try {
        await _client.restartZapret(strategyId: backup.id, mode: backup.mode.name, debug: state.debugLogs, watchdog: false);
        await Future<void>.delayed(const Duration(seconds: 1));
        accepted = (await _verify(backup.id, backup.mode)).confirmed;
        if (accepted) {
          await _client.setZapretWatchdog(state.watchdog);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_selectedStrategyPreferenceKey, backup.id);
          await prefs.setString(_modePreferenceKey, backup.mode.name);
          if (ref.mounted) state = state.copyWith(selectedStrategyId: backup.id, mode: backup.mode);
        }
      } finally {
        try {
          if (!accepted) await _client.restartZapret(strategyId: originalId, mode: originalMode.name, debug: state.debugLogs, watchdog: state.watchdog);
        } finally {
          if (ref.mounted) {
            state = state.copyWith(busy: false);
            await refresh();
          }
        }
      }
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: _errorMessage(error));
    } finally {
      _checkingFallback = false;
    }
  }

  /// Replaces an older Windows Helper service with the executable
  /// shipped beside the currently running FlClashX instance.
  Future<void> updateHelperService() async {
    if (!Platform.isWindows || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await system.updateHelperService();
      if (result == AuthorizeCode.error) {
        throw const HelperException(
          code: 'helperUpdateFailed',
          message: 'Не удалось обновить службу Helper. Проверь подтверждение UAC и повтори попытку.',
        );
      }
      if (!ref.mounted) return;
      state = state.copyWith(busy: false);
      await loadStrategies();
      await refresh();
      if (!state.available) {
        throw HelperException(
          code: 'helperZapretStillUnavailable',
          message: state.error ??
              'Служба обновлена, но каталог стратегий Zapret2 пока недоступен.',
        );
      }
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(error: _errorMessage(error));
      }
      rethrow;
    } finally {
      if (ref.mounted && state.busy) {
        state = state.copyWith(busy: false);
      }
    }
  }

  Future<void> _requireHelper() async {
    final readiness = await _client.readiness(
      timeout: _readinessTimeout,
      logFailure: false,
    );
    if (readiness != HelperReadiness.ready) {
      throw const HelperException(
        code: 'helperUnavailable',
        message: 'Служба FlClashX Helper недоступна. Перезапусти клиент и проверь установку службы.',
      );
    }
  }

  String _errorMessage(Object error) => error is HelperException
      ? error.message
      : error.toString();
}
