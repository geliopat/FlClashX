import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/zapret_infrastructure.dart';
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
  final String? testSummary;
  final List<ZapretTrial> trials;
  final int? pid;
  final Duration elapsed;
  final int cleanedProcesses;
  final String? activeStrategyId;
  final String? activeEngine;
  final String? activeMode;
  final List<String> winDivertFilters;
  final List<String> processingLists;
  final List<String> protectedDomains;
  final List<String> protectedIps;
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
    this.testSummary,
    this.trials = const [],
    this.pid,
    this.elapsed = Duration.zero,
    this.cleanedProcesses = 0,
    this.activeStrategyId,
    this.activeEngine,
    this.activeMode,
    this.winDivertFilters = const [],
    this.processingLists = const [],
    this.protectedDomains = const [],
    this.protectedIps = const [],
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
    String? testSummary,
    bool clearTestSummary = false,
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
    List<String>? protectedDomains,
    List<String>? protectedIps,
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
      testSummary: clearTestSummary ? null : testSummary ?? this.testSummary,
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
      protectedDomains: protectedDomains ?? this.protectedDomains,
      protectedIps: protectedIps ?? this.protectedIps,
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
  const ZapretTrial(this.id, this.mode, this.score, this.delay, {
    this.confirmed = false,
    this.passedTargets = 0,
    this.screenedOnly = false,
    this.error,
    this.details = const [],
  });
  final String id;
  final ZapretMode mode;
  final int score;
  final int delay;
  final bool confirmed;
  final int passedTargets;
  final bool screenedOnly;
  final String? error;
  final List<String> details;

  String get resultLabel {
    if (error != null) return 'Ошибка запуска/проверки';
    if (confirmed) return 'Успешно';
    if (screenedOnly) return passedTargets == 0
        ? 'Не прошла предварительный отбор'
        : 'Только предварительный отбор';
    return passedTargets > 0 ? 'Частично успешно' : 'Не прошла проверку';
  }
}


/// Rank fully reachable candidates first, then partially reachable ones.
List<ZapretTrial> shortlistZapretTrials(Iterable<ZapretTrial> trials, {int limit = 10}) {
  final candidates = trials.toList()
    ..sort((a, b) {
      final reachable = (b.confirmed ? 1 : 0).compareTo(a.confirmed ? 1 : 0);
      if (reachable != 0) return reachable;
      final passed = b.passedTargets.compareTo(a.passedTargets);
      if (!a.confirmed && passed != 0) return passed;
      final score = b.score.compareTo(a.score);
      if (!a.confirmed && score != 0) return score;
      final delay = (a.delay > 0 ? a.delay : 1 << 30)
          .compareTo(b.delay > 0 ? b.delay : 1 << 30);
      return delay != 0 ? delay : a.id.compareTo(b.id);
    });
  return candidates.take(limit).toList();
}

class ZapretController extends Notifier<ZapretState> {
  static const defaultStrategyId = 'flowseal-alt';
  static const _selectedStrategyPreferenceKey = 'zapret.strategyId';
  static const _modePreferenceKey = 'zapret.mode';
  static const _debugPreferenceKey = 'zapret.debugLogs';
  static const _linkedStartPreferenceKey = 'zapret.startWithMihomo';
  static const _trialHistoryKey = 'zapret.trialHistory.v3';
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
  bool _lifecycleStopping = false;
  int _lifecycleRevision = 0;
  int _failedChecks = 0;
  DateTime? _fallbackAfter;
  bool _checkingFallback = false;
  ZapretInfrastructure? _infrastructure;
  int? _infrastructureProfileId;
  bool _pendingInfrastructureRestart = false;
  bool _coreRestarting = false;
  bool _profileApplying = false;
  bool _profileBlocked = false;
  bool _desiredRunning = false;

  bool get _launchBlocked => _lifecycleStopping || _coreRestarting ||
      _profileApplying || _profileBlocked || ref.read(safeModeProvider) ||
      ref.read(coreStatusProvider) != CoreStatus.connected;

  Future<bool> beginCoreRestart({bool repairHelper = false}) async {
    _coreRestarting = true;
    final restore = state.running || _desiredRunning;
    final readiness = await _client.readiness(
      timeout: _readinessTimeout, logFailure: false,
    );
    if (readiness == HelperReadiness.ready) {
      final stopped = await stopAlongsideMihomo();
      if (repairHelper) {
        await windows!.ensureHelperReady(forceReinstall: true);
        // Verify the new service is reachable and no local engine survived.
        await stopAlongsideMihomo();
      }
      return restore || stopped;
    }
    // A dead or outdated service cannot answer the normal stop command.
    // Do not replace it while an active trial still owns the engine.
    if (state.busy) {
      _cancelTrial = true;
      throw StateError('Helper недоступен во время операции Zapret; повтори перезапуск после её завершения');
    }
    ++_lifecycleRevision;
    _lifecycleStopping = true;
    _cancelTrial = true;
    _desiredRunning = false;
    await windows!.ensureHelperReady(forceReinstall: repairHelper);
    await stopAlongsideMihomo();
    return restore;
  }

  void endCoreRestart() {
    _coreRestarting = false;
  }

  /// Pause processing BEFORE the core can start using newly introduced
  /// infrastructure addresses. Keep the launch gate closed during the apply.
  Future<({int revision, bool restore, bool wasStopping, bool changed})> beginProfileApply(
      String yaml, int? profileId) async {
    final next = ZapretInfrastructure.fromYaml(yaml);
    final changed = _infrastructure?.fingerprint != next.fingerprint ||
        _infrastructureProfileId != profileId;
    _profileApplying = changed;
    final wasStopping = _lifecycleStopping;
    var revision = _lifecycleRevision;
    var restore = false;
    try {
      if (changed && (_desiredRunning || state.running || state.busy)) {
        restore = _desiredRunning || state.running;
        final stopping = stopAlongsideMihomo();
        // Capture the revision issued by this transition, not a later
        // user/core stop that might run while the service call is pending.
        revision = _lifecycleRevision;
        restore = await stopping || restore;
      }
      return (revision: revision, restore: restore, wasStopping: wasStopping, changed: changed);
    } catch (_) {
      _profileApplying = false;
      _profileBlocked = true;
      rethrow;
    }
  }

  Future<void> finishProfileApply(
    ({int revision, bool restore, bool wasStopping, bool changed}) transition, {
    required String yaml,
    required int? profileId,
    required bool accepted,
  }) async {
    try {
      if (accepted) {
        updateInfrastructureFromYaml(yaml, profileId);
        _profileBlocked = false;
      } else {
        _infrastructure = null;
        _infrastructureProfileId = null;
        _profileBlocked = true;
        if (!transition.changed && (_desiredRunning || state.running || state.busy)) {
          await stopAlongsideMihomo();
        }
      }
    } finally {
      _profileApplying = false;
    }
    if (!transition.changed || transition.revision != _lifecycleRevision || transition.wasStopping) return;
    _lifecycleStopping = false;
    if (accepted && transition.restore && !_launchBlocked &&
        profileId == ref.read(currentProfileIdProvider)) {
      await setEnabled(true);
    }
  }

  /// Called after Mihomo accepts a new effective profile. Keep the original
  /// configuration untouched, and reconcile a running Zapret only if changed.
  void updateInfrastructureFromYaml(String yaml, int? profileId) {
    if (!Platform.isWindows || !ref.mounted) return;
    final next = ZapretInfrastructure.fromYaml(yaml);
    final previous = _infrastructure;
    final changed = previous?.fingerprint != next.fingerprint;
    _infrastructure = next;
    _infrastructureProfileId = profileId;
    state = state.copyWith(
      protectedDomains: next.domains,
      protectedIps: next.ips,
    );
    if (changed) {
      _pendingInfrastructureRestart = true;
      if (previous != null && state.testProgress != null) _cancelTrial = true;
    }
  }

  Future<ZapretInfrastructure> _readInfrastructure() async {
    final id = ref.read(currentProfileIdProvider);
    final known = _infrastructure;
    if (_profileBlocked || _profileApplying) {
      throw StateError('Конфигурация Mihomo ещё не применена');
    }
    // Never substitute a freshly downloaded but not yet applied profile.
    if (known != null && _infrastructureProfileId == id) return known;
    throw StateError('Нет подтверждённой конфигурации Mihomo для защиты Zapret');
  }

  Future<void> refreshInfrastructure() async {
    if (state.busy || _launchBlocked) return;
    final protection = await _readInfrastructure();
    if (_launchBlocked) return;
    state = state.copyWith(protectedDomains: protection.domains, protectedIps: protection.ips);
    if (state.running) await restart();
  }

  Future<void> _reconcileInfrastructure() async {
    if (!_pendingInfrastructureRestart || _launchBlocked ||
        !state.running || state.busy || _refreshing) {
      return;
    }
    _pendingInfrastructureRestart = false;
    try {
      await restart();
    } catch (_) {
      // restart() already exposes its error; never loop on a failed restart.
    }
  }

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
        if (ref.mounted) {
          unawaited(refresh().then((_) {
            if (ref.mounted) return _reconcileInfrastructure();
          }));
        }
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
        trials: _restoreTrials(preferences, strategies.map((item) => item.id).toSet()),
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
        strategies: const [],
        error: _errorMessage(error),
      );
    }
  }

  List<ZapretTrial> _restoreTrials(SharedPreferences prefs, Set<String> installed) {
    try {
      final saved = prefs.getString(_trialHistoryKey);
      if (saved == null) return const [];
      final data = jsonDecode(saved) as Map<String, dynamic>;
      final at = DateTime.parse(data['at'] as String);
      if (DateTime.now().difference(at).abs() > const Duration(days: 7)) return const [];
      return [
        for (final item in data['trials'] as List)
          if (installed.contains(item['id']))
            ZapretTrial(
              item['id'] as String,
              ZapretMode.values.byName(item['mode'] as String),
              item['score'] as int,
              item['delay'] as int,
              confirmed: item['confirmed'] == true,
              passedTargets: item['passedTargets'] as int? ?? 0,
              screenedOnly: item['screenedOnly'] == true,
              error: item['error'] as String?,
              details: List<String>.from(item['details'] as List? ?? const []),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveTrials(List<ZapretTrial> trials) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_trialHistoryKey, jsonEncode({
      'at': DateTime.now().toIso8601String(),
      'trials': [
        for (final item in trials)
          {
            'id': item.id,
            'mode': item.mode.name,
            'score': item.score,
            'delay': item.delay,
            'confirmed': item.confirmed,
            'passedTargets': item.passedTargets,
            'screenedOnly': item.screenedOnly,
            'error': item.error,
            'details': item.details,
          },
      ],
    }));
  }

  Future<void> selectStrategy(String strategyId) =>
      _applySelection(strategyId, state.mode);

  Future<void> setMode(ZapretMode mode) async {
    if (!state.supportsSplitMode) return;
    await _applySelection(state.selectedStrategyId, mode);
  }

  Future<void> _applySelection(String strategyId, ZapretMode mode,
      {bool startIfStopped = false}) async {
    if (state.busy) return;
    final strategy = state.strategies.where((item) => item.id == strategyId).firstOrNull;
    if (strategy == null) {
      throw ArgumentError.value(strategyId, 'strategyId', 'Unknown Zapret strategy');
    }
    final effectiveMode = strategy.supportsSplitMode ? mode : ZapretMode.fullBypass;
    final previousId = state.selectedStrategyId;
    final previousMode = state.mode;
    final wasRunning = state.running;
    state = state.copyWith(selectedStrategyId: strategyId, mode: effectiveMode, clearError: true);
    try {
      if (wasRunning && (state.activeStrategyId != strategyId || state.activeMode != effectiveMode.name)) {
        await restart();
      } else if (!wasRunning && startIfStopped) {
        await setEnabled(true);
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_selectedStrategyPreferenceKey, strategyId);
      await preferences.setString(_modePreferenceKey, effectiveMode.name);
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(selectedStrategyId: previousId, mode: previousMode, error: _errorMessage(error));
      }
      rethrow;
    }
  }

  Future<void> setStartWithMihomo(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_linkedStartPreferenceKey, enabled);
    if (ref.mounted) state = state.copyWith(startWithMihomo: enabled);
  }

  /// Start only after the new Mihomo run is ready. A later stop supersedes this.
  Future<void> startAlongsideMihomo({bool force = false}) async {
    if (!Platform.isWindows || !ref.mounted || _coreRestarting) return;
    final revision = ++_lifecycleRevision;
    final preferences = await SharedPreferences.getInstance();
    if (!ref.mounted || revision != _lifecycleRevision || _coreRestarting) return;
    _lifecycleStopping = false;
    if (_launchBlocked || (!force && preferences.getBool(_linkedStartPreferenceKey) != true)) return;
    await loadStrategies();
    await refresh();
    if (ref.mounted && revision == _lifecycleRevision && !state.available) {
      throw HelperException(code: 'helperZapretStillUnavailable', message: state.error ?? 'Каталог Zapret недоступен');
    }
    if (ref.mounted && revision == _lifecycleRevision && !_launchBlocked &&
        state.available && !state.busy && !state.running) {
      await setEnabled(true);
    }
  }

  /// Cancel trials and suppress restoration before stopping the service.
  Future<bool> stopAlongsideMihomo() async {
    if (!Platform.isWindows || !ref.mounted) return false;
    ++_lifecycleRevision;
    _lifecycleStopping = true;
    _cancelTrial = true;
    final wasRunning = state.running || _desiredRunning;
    _desiredRunning = false;
    final readiness = await _client.readiness(timeout: _readinessTimeout, logFailure: false);
    if (readiness != HelperReadiness.ready) {
      if (wasRunning || state.busy) {
        throw StateError('Helper недоступен: остановка Zapret не подтверждена');
      }
      return false;
    }
    final before = await _client.zapretStatus();
    // Stop immediately; the service rejects any earlier command arriving late.
    await _client.stopZapret();
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (ref.mounted && state.busy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!ref.mounted) return wasRunning || before.running;
    if (state.busy) {
      throw StateError('Операция Zapret не завершилась после остановки');
    }
    // Confirm again after all Dart workers have drained.
    final stopped = await _client.stopZapret();
    if (stopped.running) throw StateError('Zapret продолжает работать');
    await refresh();
    return wasRunning || before.running;
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
      );
    } on HelperException catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        available: false,
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
        available: false,
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
    if (enabled && _launchBlocked) return;
    if (!enabled) _desiredRunning = false;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _requireHelper();
      final protection = enabled ? await _readInfrastructure() : null;
      if (enabled && _launchBlocked) return;
      final response = enabled
          ? await _client.startZapret(
              infrastructure: protection!.toJson(),
              strategyId: state.selectedStrategyId,
              debug: state.debugLogs,
              watchdog: state.watchdog,
              mode: (state.supportsSplitMode ? state.mode : ZapretMode.fullBypass).name,
            )
          : await _client.stopZapret();
      if (!ref.mounted) return;
      if (enabled) _desiredRunning = response.running && !_launchBlocked;
      if (enabled && protection?.fingerprint == _infrastructure?.fingerprint) {
        _pendingInfrastructureRestart = false;
      }
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
    if (!Platform.isWindows || state.busy || _launchBlocked) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _requireHelper();
      final protection = await _readInfrastructure();
      if (_launchBlocked) return;
      final response = await _client.restartZapret(
        infrastructure: protection.toJson(),
        strategyId: state.selectedStrategyId,
              debug: state.debugLogs,
              watchdog: state.watchdog,
        mode: (state.supportsSplitMode ? state.mode : ZapretMode.fullBypass).name,
      );
      if (!ref.mounted) return;
      _desiredRunning = response.running && !_launchBlocked;
      if (protection.fingerprint == _infrastructure?.fingerprint) {
        _pendingInfrastructureRestart = false;
      }
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
    if (state.busy || _launchBlocked) return;
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

  Future<ZapretTrial> _verify(String id, ZapretMode mode, {
    int timeoutMs = 3500,
    int? expectedPid,
  }) async {
    const targets = [ZapretProbeTarget.youtube, ZapretProbeTarget.discordGateway, ZapretProbeTarget.discordVoice];
    final before = await _client.zapretStatus();
    if (!before.running || before.strategyId != id || before.pid == null ||
        (expectedPid != null && before.pid != expectedPid)) {
      throw StateError('Движок стратегии не запущен: $id');
    }
    final items = await measureZapretTargets(ref, targets, timeoutMs: timeoutMs);
    final good = items.values.where((item) => item.message == 'DIRECT · HTTP 2xx' && item.latencyMs != null && item.latencyMs! > 0).toList();
    final score = good.fold<int>(0, (sum, item) => sum + (item.latencyMs! <= 450 ? 2 : 1));
    final delay = good.isEmpty ? 0 : (good.fold<int>(0, (sum, item) => sum + item.latencyMs!) / good.length).round();
    final status = await _client.zapretStatus();
    final sameProcess = status.running && status.strategyId == id && status.pid == before.pid;
    final details = [
      for (final target in targets)
        '${target.label}: ${items[target]?.message ?? 'Нет результата'}'
        '${items[target]?.latencyMs == null ? '' : ' · ${items[target]!.latencyMs} мс'}',
      if (!sameProcess) 'Движок остановился или сменил PID во время проверки',
    ];
    return ZapretTrial(id, mode, sameProcess ? score : 0,
        sameProcess ? delay : 0,
        confirmed: sameProcess && good.length == targets.length,
        passedTargets: sameProcess ? good.length : 0,
        error: sameProcess ? null : 'Движок завершился во время проверки',
        details: details);
  }

  Future<void> testStrategies() async {
    if (!Platform.isWindows || state.busy || _launchBlocked || state.strategies.isEmpty ||
        ref.read(coreStatusProvider) != CoreStatus.connected) {
      if (ref.mounted && !state.busy) {
        state = state.copyWith(testSummary: 'Нужны подключённое ядро Mihomo и каталог стратегий.');
      }
      return;
    }
    _cancelTrial = false;
    final previousTrials = state.trials;
    final strategies = state.strategies.toList();
    final selectedMode = state.mode;
    state = state.copyWith(busy: true, trials: const [], testProgress: 'Подготовка', clearTestSummary: true, clearError: true);
    final results = <ZapretTrial>[];
    final preliminary = <ZapretTrial>[];
    HelperZapretStatus? original;
    var trialStarted = false;
    var attempted = 0;
    var finalists = 0;
    var verified = 0;
    var launchFailures = 0;
    String? lastLaunchFailure;
    String? failure;
    try {
      await _requireHelper();
      original = await _client.zapretStatus();
      final protection = await _readInfrastructure();
      for (var i = 0; i < strategies.length && !_cancelTrial && !_launchBlocked; i++) {
        final item = strategies[i];
        final mode = item.supportsSplitMode ? selectedMode : ZapretMode.fullBypass;
        attempted++;
        state = state.copyWith(testProgress: '1/2 · ${i + 1}/${strategies.length}: ${item.name}');
        try {
          trialStarted = true;
          final started = await _client.restartZapret(
            strategyId: item.id, mode: mode.name, watchdog: false,
            infrastructure: protection.toJson(),
          );
          if (!started.running || started.strategyId != item.id || started.pid == null) {
            throw StateError('Стратегия не запустилась');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          if (_cancelTrial || _launchBlocked) break;
          final first = await _verify(item.id, mode, timeoutMs: 2000, expectedPid: started.pid);
          if (_cancelTrial || _launchBlocked) break;
          if (first.error == null) preliminary.add(first);
          if (first.error != null) {
            launchFailures++;
            lastLaunchFailure = first.error;
          }
          // Screening alone never makes a strategy eligible for activation.
          results.add(ZapretTrial(item.id, mode, first.score, first.delay,
            passedTargets: first.passedTargets, screenedOnly: true,
            error: first.error, details: first.details));
        } catch (error) {
          launchFailures++;
          lastLaunchFailure = _errorMessage(error);
          results.add(ZapretTrial(item.id, mode, 0, 0, error: lastLaunchFailure));
          if (error is HelperException && error.code == 'zapretConflict') {
            failure = lastLaunchFailure;
            break;
          }
        }
      }
      final candidates = shortlistZapretTrials(preliminary);
      finalists = candidates.length;
      for (final candidate in candidates) {
        if (_cancelTrial || _launchBlocked || failure != null) break;
        final item = strategies.firstWhere((s) => s.id == candidate.id);
        verified++;
        state = state.copyWith(testProgress: '2/2 · $verified/$finalists: ${item.name}');
        try {
          final started = await _client.restartZapret(
            strategyId: candidate.id, mode: candidate.mode.name,
            watchdog: false, infrastructure: protection.toJson(),
          );
          if (!started.running || started.strategyId != candidate.id || started.pid == null) {
            throw StateError('Стратегия не запустилась');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          if (_cancelTrial || _launchBlocked) break;
          final first = await _verify(candidate.id, candidate.mode, expectedPid: started.pid);
          if (_cancelTrial || _launchBlocked) break;
          var result = first;
          if (first.confirmed) {
            final second = await _verify(candidate.id, candidate.mode, expectedPid: started.pid);
            if (_cancelTrial || _launchBlocked) break;
            result = ZapretTrial(candidate.id, candidate.mode,
              ((first.score + second.score) / 2).round(),
              second.confirmed ? ((first.delay + second.delay) / 2).round() : second.delay,
              confirmed: second.confirmed, passedTargets: second.passedTargets,
              error: second.error,
              details: ['Контроль 1:', ...first.details, 'Контроль 2:', ...second.details]);
          }
          if (result.error != null) {
            launchFailures++;
            lastLaunchFailure = result.error;
          }
          results.removeWhere((trial) => trial.id == candidate.id);
          results.add(result);
        } catch (error) {
          launchFailures++;
          lastLaunchFailure = _errorMessage(error);
          results.removeWhere((trial) => trial.id == candidate.id);
          results.add(ZapretTrial(candidate.id, candidate.mode, 0, 0, error: lastLaunchFailure, details: candidate.details));
          if (error is HelperException && error.code == 'zapretConflict') {
            failure = lastLaunchFailure;
            break;
          }
        }
      }
      final ranked = shortlistZapretTrials(results, limit: results.length);
      results
        ..clear()
        ..addAll(ranked);
    } catch (error) {
      failure = _errorMessage(error);
    } finally {
      try {
        if (_launchBlocked) {
          await _client.stopZapret();
        } else if (trialStarted) {
          if (original == null || !original.running || original.strategyId == null) {
            await _client.stopZapret();
          } else {
            final protection = await _readInfrastructure();
            if (!_launchBlocked) {
              await _client.restartZapret(strategyId: original.strategyId!,
                mode: original.mode ?? 'fullBypass', debug: state.debugLogs,
                watchdog: state.watchdog, infrastructure: protection.toJson());
              if (protection.fingerprint == _infrastructure?.fingerprint) {
                _pendingInfrastructureRestart = false;
              }
            }
          }
        }
      } catch (error) {
        failure = 'Не удалось восстановить исходное состояние: ${_errorMessage(error)}';
      }
      if (ref.mounted) {
        final summary = _cancelTrial ? 'Тест отменён · предыдущие результаты сохранены' :
            'Отбор $attempted/${strategies.length} · контроль $verified/$finalists · операций с ошибками $launchFailures'
            '${lastLaunchFailure == null ? '' : '\nПоследняя ошибка: $lastLaunchFailure'}';
        state = state.copyWith(busy: false, clearTestProgress: true,
            testSummary: summary, trials: _cancelTrial ? previousTrials : List.unmodifiable(results), error: failure);
        if (!_cancelTrial && failure == null) {
          try { await _saveTrials(results); } catch (_) { /* History is optional. */ }
        }
        await refresh();
      }
    }
  }

  Future<void> applyTrial(ZapretTrial trial) async {
    if (state.busy || !trial.confirmed) return;
    await _applySelection(trial.id, trial.mode, startIfStopped: true);
  }

  Future<void> checkFallback(Map<ZapretProbeTarget, ZapretProbeResult> checks) async {
    if (_launchBlocked || _checkingFallback || state.busy || !state.running || !state.autoFallback ||
        state.activeStrategyId == null ||
        ref.read(coreStatusProvider) != CoreStatus.connected ||
        (_fallbackAfter != null && DateTime.now().isBefore(_fallbackAfter!))) {
      return;
    }
    final backup = state.trials.where((trial) =>
        trial.confirmed && trial.id != state.activeStrategyId).firstOrNull;
    if (backup == null) return;
    _checkingFallback = true;
    try {
      final originalId = state.activeStrategyId!;
      final originalMode = state.activeMode == 'strictSplit' ? ZapretMode.strictSplit : ZapretMode.fullBypass;
      const required = [ZapretProbeTarget.youtube, ZapretProbeTarget.discordGateway, ZapretProbeTarget.discordVoice];
      final current = required.map((target) => checks[target]).toList();
      if (current.any((item) => item == null || item.status == ZapretProbeStatus.checking)) {
        _failedChecks = 0;
        return;
      }
      if (state.busy || state.activeStrategyId != originalId || !state.running) return;
      if (!state.autoFallback || ref.read(coreStatusProvider) != CoreStatus.connected) return;
      if (current.every((item) => item?.message == 'DIRECT · HTTP 2xx')) {
        _failedChecks = 0;
        return;
      }
      if (++_failedChecks < 3) return;
      _failedChecks = 0;
      _fallbackAfter = DateTime.now().add(const Duration(minutes: 5));
      state = state.copyWith(busy: true);
      var accepted = false;
      try {
        final protection = await _readInfrastructure();
        if (_launchBlocked) return;
        await _client.restartZapret(strategyId: backup.id, mode: backup.mode.name,
          debug: state.debugLogs, watchdog: false, infrastructure: protection.toJson());
        await Future<void>.delayed(const Duration(seconds: 1));
        accepted = (await _verify(backup.id, backup.mode)).confirmed && !_launchBlocked;
        if (accepted && !_launchBlocked) {
          await _client.setZapretWatchdog(state.watchdog);
          if (_launchBlocked) return;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_selectedStrategyPreferenceKey, backup.id);
          await prefs.setString(_modePreferenceKey, backup.mode.name);
          if (ref.mounted) state = state.copyWith(selectedStrategyId: backup.id, mode: backup.mode);
        }
      } finally {
        try {
          if (_launchBlocked) {
            await _client.stopZapret();
          } else if (!accepted) {
            final protection = await _readInfrastructure();
            if (!_launchBlocked) {
              await _client.restartZapret(strategyId: originalId, mode: originalMode.name,
                debug: state.debugLogs, watchdog: state.watchdog, infrastructure: protection.toJson());
            }
          }
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
  /// shipped beside the currently running FlClashZ instance.
  Future<void> updateHelperService() async {
    if (!Platform.isWindows || state.busy || ref.read(safeModeProvider)) return;
    state = state.copyWith(clearError: true);
    try {
      // Run repair inside the core restart worker, which gates Zapret and
      // restores the user's run intent only after the new service is ready.
      final restored = await ref.read(coreActionProvider.notifier)
          .restartCore(repairHelper: true);
      if (!restored) {
        throw const HelperException(
          code: 'helperUpdateFailed',
          message: 'Не удалось восстановить Mihomo после обновления Helper',
        );
      }
      if (!ref.mounted) return;
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
    }
  }

  Future<void> _requireHelper() async {
    final readiness = await _client.readiness(
      timeout: _readinessTimeout,
      logFailure: false,
      verifyHelperBinary: true,
    );
    if (readiness != HelperReadiness.ready) {
      throw const HelperException(
        code: 'helperUnavailable',
        message: 'Служба Helper недоступна. Перезапусти клиент и проверь установку службы.',
      );
    }
  }

  String _errorMessage(Object error) => error is HelperException
      ? error.message
      : error.toString();
}
