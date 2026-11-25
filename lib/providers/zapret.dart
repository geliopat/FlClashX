import 'package:fl_clash/l10n/l10n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/common/file_logger.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart' show isStartProvider;
import 'package:fl_clash/providers/zapret_infrastructure.dart';
import 'package:fl_clash/providers/zapret_diagnostics.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final zapretControllerProvider =
    NotifierProvider<ZapretController, ZapretState>(ZapretController.new);

enum ZapretMode { strictSplit, fullBypass }

enum ZapretAutoTuneMode {
  veryFast(1),
  fast(2),
  full(2);

  const ZapretAutoTuneMode(this.controlRuns);
  String get label => localizedLabel(AppLocalizations());
  String get description => localizedDescription(AppLocalizations());
  final int controlRuns;

  String localizedLabel(AppLocalizations l) => switch (this) {
    ZapretAutoTuneMode.veryFast => l.forkVeryFast,
    ZapretAutoTuneMode.fast => l.forkFast,
    ZapretAutoTuneMode.full => l.forkFull,
  };
  String localizedDescription(AppLocalizations l) => switch (this) {
    ZapretAutoTuneMode.veryFast => l.forkVeryFastDesc,
    ZapretAutoTuneMode.fast => l.forkFastDesc,
    ZapretAutoTuneMode.full => l.forkFullDesc,
  };
  bool get screenFirst => this != ZapretAutoTuneMode.full;
  bool shouldStop(ZapretTrial trial) => this == ZapretAutoTuneMode.veryFast &&
      !trial.screenedOnly && trial.error == null && trial.confirmed && trial.score == 6;
}

class ZapretState {
  final bool available;
  final bool running;
  final bool busy;
  final bool dashboardRestarting;
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
    this.dashboardRestarting = false,
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
    bool? dashboardRestarting,
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
      dashboardRestarting: dashboardRestarting ?? this.dashboardRestarting,
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

  Map<String, Object?> toHistoryJson() => {
    'id': id,
    'mode': mode.name,
    'score': score,
    'delay': delay,
    'confirmed': confirmed,
    'passedTargets': passedTargets,
    'screenedOnly': screenedOnly,
    'error': error,
    'details': details,
  };

  factory ZapretTrial.fromHistoryJson(Map<String, dynamic> item) => ZapretTrial(
    item['id'] as String,
    ZapretMode.values.byName(item['mode'] as String),
    item['score'] as int,
    item['delay'] as int,
    confirmed: item['confirmed'] == true,
    passedTargets: item['passedTargets'] as int? ?? 0,
    screenedOnly: item['screenedOnly'] == true,
    error: item['error'] as String?,
    details: List<String>.from(item['details'] as List? ?? const []),
  );

  String localizedResultLabel(AppLocalizations l) {
    if (error != null) return l.forkTrialError;
    if (confirmed) return l.forkSuccess;
    if (screenedOnly) return passedTargets == 0 ? l.forkScreenFailed : l.forkScreenOnly;
    return score > 0 ? l.forkPartialSuccess : l.forkTestFailed;
  }

  String get resultLabel => localizedResultLabel(AppLocalizations());
}


const zapretHistoryLimit = 30;
const _zapretArchiveKey = 'zapret.completedRuns.v1';
const _zapretLatestKey = 'zapret.trialHistory.v5';

class ZapretTuneRun {
  const ZapretTuneRun({
    required this.at,
    required this.trials,
    this.tuneMode,
    this.duration,
    this.totalStrategies,
    this.summary,
    this.failure,
  });

  final DateTime at;
  final List<ZapretTrial> trials;
  final ZapretAutoTuneMode? tuneMode;
  final Duration? duration;
  final int? totalStrategies;
  final String? summary;
  final String? failure;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'tuneMode': tuneMode?.name,
    'durationMs': duration?.inMilliseconds,
    'totalStrategies': totalStrategies,
    'summary': summary,
    'failure': failure,
    'trials': trials.map((trial) => trial.toHistoryJson()).toList(),
  };

  factory ZapretTuneRun.fromJson(Map<String, dynamic> json) {
    final mode = json['tuneMode'] as String?;
    final millis = json['durationMs'] as int?;
    return ZapretTuneRun(
      at: DateTime.parse(json['at'] as String),
      trials: List.unmodifiable(
        (json['trials'] as List).map((item) =>
          ZapretTrial.fromHistoryJson(Map<String, dynamic>.from(item as Map))),
      ),
      tuneMode: ZapretAutoTuneMode.values.where((value) => value.name == mode).firstOrNull,
      duration: millis == null ? null : Duration(milliseconds: millis),
      totalStrategies: json['totalStrategies'] as int?,
      summary: json['summary'] as String?,
      failure: json['failure'] as String?,
    );
  }
}

List<ZapretTuneRun> decodeZapretHistory(String? archive, String? legacy) {
  final runs = <ZapretTuneRun>[];
  try {
    final data = archive == null
        ? (legacy == null ? <Object>[] : [jsonDecode(legacy)])
        : jsonDecode(archive) as List;
    for (final item in data) {
      try {
        runs.add(ZapretTuneRun.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {
        // Preserve other valid runs even if one entry is obsolete or damaged.
      }
    }
  } catch (_) {
    // Corrupt history is not allowed to break the engine or latest results.
  }
  runs.sort((a, b) => b.at.compareTo(a.at));
  return runs.take(zapretHistoryLimit).toList();
}

Future<List<ZapretTuneRun>> loadZapretTuneHistory() async {
  final prefs = await SharedPreferences.getInstance();
  return decodeZapretHistory(
    prefs.getString(_zapretArchiveKey), prefs.getString(_zapretLatestKey),
  );
}

Future<void> saveZapretTuneRun(ZapretTuneRun run) async {
  final prefs = await SharedPreferences.getInstance();
  final previous = decodeZapretHistory(
    prefs.getString(_zapretArchiveKey), prefs.getString(_zapretLatestKey),
  );
  final history = [run, ...previous].take(zapretHistoryLimit).toList();
  if (!await prefs.setString(_zapretArchiveKey, jsonEncode(history.map((item) => item.toJson()).toList()))) {
    throw StateError(AppLocalizations().forkHistorySaveFailed);
  }
}

/// Full results are ranked by original points, then HTTPS latency.
/// YouTube-only screening has a different scale, so it follows full results.
List<ZapretTrial> shortlistZapretTrials(Iterable<ZapretTrial> trials, {int limit = 10}) {
  final candidates = trials.toList()
    ..sort((a, b) {
      final phase = (a.screenedOnly ? 1 : 0).compareTo(b.screenedOnly ? 1 : 0);
      if (phase != 0) return phase;
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final delay = (a.delay > 0 ? a.delay : 1 << 30)
          .compareTo(b.delay > 0 ? b.delay : 1 << 30);
      return delay != 0 ? delay : a.id.compareTo(b.id);
    });
  return candidates.take(limit).toList();
}

List<ZapretTrial> selectZapretFinalists(Iterable<ZapretTrial> trials) =>
    shortlistZapretTrials(trials.where((trial) =>
      trial.screenedOnly && trial.error == null && trial.score > 0), limit: 5);

/// Keep the worse of two full scores (both runs must actually pass).
ZapretTrial combineZapretControlRuns(ZapretTrial first, ZapretTrial second, {String? runLabel}) {
  final label = runLabel ?? AppLocalizations().forkControlRun;
  final error = first.error ?? second.error;
  return ZapretTrial(first.id, first.mode,
    error != null ? 0 : first.score < second.score ? first.score : second.score,
    error != null || first.delay == 0 || second.delay == 0
        ? 0 : ((first.delay + second.delay) / 2).round(),
    confirmed: error == null && first.confirmed && second.confirmed,
    passedTargets: error != null ? 0 : first.passedTargets < second.passedTargets
        ? first.passedTargets : second.passedTargets,
    error: error,
    details: ['$label 1:', ...first.details, '$label 2:', ...second.details],
  );
}

class ZapretController extends Notifier<ZapretState> {
  static const defaultStrategyId = 'flowseal-alt';
  static const _selectedStrategyPreferenceKey = 'zapret.strategyId';
  static const _modePreferenceKey = 'zapret.mode';
  static const _debugPreferenceKey = 'zapret.debugLogs';
  static const _linkedStartPreferenceKey = 'zapret.startWithMihomo';
  static const _trialHistoryKey = _zapretLatestKey;
  static const _pollInterval = Duration(seconds: 3);
  static const _readinessTimeout = Duration(seconds: 3);

  final HelperClient _client = helperClient;
  Timer? _poller;
  Timer? _clock;
  bool _collectingLogs = false;
  final _seenLogEvents = <String>{};

  Future<void> collectPersistentLogs() async {
    if (_collectingLogs || !Platform.isWindows) return;
    _collectingLogs = true;
    try {
      final logs = await _client.zapretLogs();
      zapretFileLogger.enable();
      crashFileLogger.enable();
      for (final entry in logs) {
        final key = '${entry.time.millisecondsSinceEpoch}|${entry.level}|${entry.message}';
        if (!_seenLogEvents.add(key)) continue;
        final log = Log(dateTime: entry.time.toLocal().toIso8601String(),
          logLevel: entry.level == 'error' ? LogLevel.error : entry.level == 'debug' ? LogLevel.debug : LogLevel.info,
          payload: '[${entry.level}] ${entry.message}');
        zapretFileLogger.write(log);
        if (entry.message.toLowerCase().contains('watchdog') ||
            entry.message.toLowerCase().contains('engine exited')) {
          crashFileLogger.write(log.copyWith(payload: '[Zapret] ${log.payload}'));
        }
      }
      while (_seenLogEvents.length > 2000) {
        _seenLogEvents.remove(_seenLogEvents.first);
      }
    } catch (_) {
      // A stopped or replacing Helper is not a log event.
    } finally {
      _collectingLogs = false;
    }
  }
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
      throw StateError(AppLocalizations().forkHelperBusy);
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
      await setEnabled(true, reason: 'profile_apply');
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
      throw StateError(AppLocalizations().forkCoreNotApplied);
    }
    // Never substitute a freshly downloaded but not yet applied profile.
    if (known != null && _infrastructureProfileId == id) return known;
    throw StateError(AppLocalizations().forkCoreProtectionMissing);
  }

  Future<void> refreshInfrastructure() async {
    if (state.busy || _launchBlocked) return;
    final protection = await _readInfrastructure();
    if (_launchBlocked) return;
    state = state.copyWith(protectedDomains: protection.domains, protectedIps: protection.ips);
    if (state.running) await restart(reason: 'infrastructure_refresh');
  }

  Future<void> _reconcileInfrastructure() async {
    if (!_pendingInfrastructureRestart || _launchBlocked ||
        !state.running || state.busy || _refreshing) {
      return;
    }
    _pendingInfrastructureRestart = false;
    try {
      await restart(reason: 'infrastructure_changed');
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
        unawaited(collectPersistentLogs());
      });
      _poller = Timer.periodic(_pollInterval, (_) {
        if (ref.mounted) {
          unawaited(collectPersistentLogs());
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
        await restart(reason: 'strategy_change');
      } else if (!wasRunning && startIfStopped) {
        await setEnabled(true, reason: 'strategy_change');
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
      throw HelperException(code: 'helperZapretStillUnavailable', message: state.error ?? AppLocalizations().forkCatalogUnavailable);
    }
    if (ref.mounted && revision == _lifecycleRevision && !_launchBlocked &&
        state.available && !state.busy && !state.running) {
      await setEnabled(true, reason: force ? 'mihomo_restore' : 'mihomo_start');
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
        throw StateError(AppLocalizations().forkStopUnconfirmed);
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
      throw StateError(AppLocalizations().forkStopPending);
    }
    // Confirm again after all Dart workers have drained.
    final stopped = await _client.stopZapret();
    if (stopped.running) throw StateError(AppLocalizations().forkStillRunning);
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

  Future<void> setEnabled(bool enabled, {String reason = 'manual'}) async {
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
              reason: reason,
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

  /// Explicit dashboard recovery is allowed even when the Helper catalog
  /// could not be loaded. Do not replace a service outside the coordinated
  /// core restart: it may own both processes.
  Future<void> restartFromDashboard({bool restartAll = false}) async {
    if (!Platform.isWindows || !ref.mounted || state.busy ||
        state.dashboardRestarting || _coreRestarting || _profileApplying ||
        ref.read(safeModeProvider)) {
      return;
    }
    final expectedZapret = state.running || _desiredRunning || state.startWithMihomo;
    state = state.copyWith(dashboardRestarting: true, clearError: true);
    try {
      // Keep other strategy operations out of the read-only preflight,
      // but release busy before the restart worker drains Zapret.
      state = state.copyWith(busy: true);
      final bool needsRepair;
      try {
        needsRepair = await windows!.helperNeedsRepair();
      } finally {
        if (ref.mounted) state = state.copyWith(busy: false);
      }
      if (!ref.mounted) return;
      if (_coreRestarting || _profileApplying || ref.read(safeModeProvider)) {
        throw StateError(AppLocalizations().forkCoreBusy);
      }
      if (restartAll || needsRepair || ref.read(coreStatusProvider) != CoreStatus.connected) {
        final restored = await ref.read(coreActionProvider.notifier)
            .restartCore(repairHelper: needsRepair);
        if (!ref.mounted) return;
        if (!restored || ref.read(coreStatusProvider) != CoreStatus.connected) {
          throw const HelperException(
            code: 'helperUpdateFailed',
            message: AppLocalizations().forkCoreRecoveryFailed,
          );
        }
        if (restartAll) {
          // The shared restart worker already restored the running intent.
          // Do not launch an explicitly disabled engine a second time.
          if (expectedZapret && ref.read(isStartProvider) && !state.running) {
            await refresh();
            if (ref.mounted && ref.read(isStartProvider) && !state.running) {
              throw StateError(state.error ?? AppLocalizations().forkCoreRecoveredZapretStopped);
            }
          }
          return;
        }
        await loadStrategies();
        await refresh();
        if (!ref.mounted) return;
        if (!state.available) {
          throw HelperException(
            code: 'helperZapretStillUnavailable',
            message: state.error ?? AppLocalizations().forkCatalogUnavailable,
          );
        }
        // The core restart already restores a previously running Zapret.
        // An explicit dashboard start also starts it if it had been off,
        // but never overrides a VPN stop made during the repair.
        if (!state.running && ref.read(isStartProvider) && !_launchBlocked) {
          await restart(reason: 'dashboard');
        }
        if (!ref.mounted) return;
        if (!state.running) {
          throw StateError(ref.read(isStartProvider)
              ? AppLocalizations().forkHelperCheckedZapretStopped
              : AppLocalizations().forkHelperCheckedStartCore);
        }
        return;
      }
      if (!state.available) await loadStrategies();
      if (!ref.mounted) return;
      if (!state.available || _launchBlocked) {
        throw StateError(state.error ?? AppLocalizations().forkLaunchUnavailable);
      }
      await restart(reason: 'dashboard');
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: _errorMessage(error));
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(dashboardRestarting: false);
    }
  }

  /// Restart also runs the upstream GUI's orphaned-process cleanup in Helper
  /// before it starts the selected winws.exe or winws2.exe profile.
  Future<void> restart({String reason = 'manual'}) async {
    if (!Platform.isWindows || state.busy || _launchBlocked) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _requireHelper();
      final protection = await _readInfrastructure();
      if (_launchBlocked) return;
      final response = await _client.restartZapret(
        reason: reason,
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
    bool screenOnly = false,
  }) async {
    final l = AppLocalizations();
    const required = [ZapretProbeTarget.youtube, ZapretProbeTarget.discordGateway, ZapretProbeTarget.discordVoice];
    final targets = screenOnly ? const [ZapretProbeTarget.youtube] : ZapretProbeTarget.values;
    final before = await _client.zapretStatus();
    if (!before.running || before.strategyId != id || before.pid == null ||
        (expectedPid != null && before.pid != expectedPid)) {
      throw StateError('${l.forkStrategyLaunchFailed}: $id');
    }
    final items = await measureZapretTargets(ref, targets, timeoutMs: timeoutMs);
    final scored = (screenOnly ? targets : required).map((target) => items[target])
        .whereType<ZapretProbeResult>().toList();
    final reachable = scored.where((item) => item.score > 0 &&
        item.latencyMs != null && item.latencyMs! > 0).toList();
    final score = reachable.fold<int>(0, (sum, item) => sum + item.score);
    final delay = reachable.isEmpty ? 0 :
        (reachable.fold<int>(0, (sum, item) => sum + item.latencyMs!) / reachable.length).round();
    final confirmed = !screenOnly && scored.length == required.length &&
        scored.every((item) => item.accepted && item.score > 0);
    final status = await _client.zapretStatus();
    final sameProcess = status.running && status.strategyId == id && status.pid == before.pid;
    final details = [
      for (final target in targets)
        '${target.label}${target == ZapretProbeTarget.googleVideo ? ' (${l.forkAdditional})' : ''}: ${items[target]?.localizedStatusLabel(l) ?? l.forkUnconfirmed} · ${items[target]?.message ?? l.forkNoVerifiedResult}${items[target]?.latencyMs == null ? '' : ' · ${items[target]!.latencyMs} ms'}',
      if (!sameProcess) l.forkEngineChanged,
    ];
    return ZapretTrial(id, mode, sameProcess ? score : 0,
        sameProcess ? delay : 0,
        confirmed: sameProcess && confirmed,
        screenedOnly: screenOnly,
        passedTargets: sameProcess ? reachable.length : 0,
        error: sameProcess ? null : l.forkEngineExited,
        details: details);
  }

  Future<void> testStrategies({ZapretAutoTuneMode tuneMode = ZapretAutoTuneMode.fast}) async {
    final l = AppLocalizations();
    final controlLabel = l.forkControlRun;
    if (!Platform.isWindows || state.busy || _launchBlocked || state.strategies.isEmpty ||
        ref.read(coreStatusProvider) != CoreStatus.connected) {
      if (ref.mounted && !state.busy) {
        state = state.copyWith(testSummary: l.forkTuneRequirements);
      }
      return;
    }
    _cancelTrial = false;
    final previousTrials = state.trials;
    final runClock = Stopwatch()..start();
    final strategies = state.strategies.toList();
    final selectedMode = state.mode;
    state = state.copyWith(busy: true, trials: const [], testProgress: l.forkPreparing, clearTestSummary: true, clearError: true);
    final results = <String, ZapretTrial>{};
    HelperZapretStatus? original;
    var trialStarted = false;
    var attempted = 0;
    var finalists = 0;
    var verified = 0;
    var launchFailures = 0;
    var earlyStop = false;
    String? lastLaunchFailure;
    String? failure;
    try {
      await _requireHelper();
      original = await _client.zapretStatus();
      final protection = await _readInfrastructure();
      bool cancelled() => _cancelTrial || _launchBlocked || failure != null;

      Future<ZapretTrial?> probe(HelperZapretStrategy item, ZapretMode mode, {required bool screen}) async {
        try {
          if (cancelled()) return null;
          trialStarted = true;
          final started = await _client.restartZapret(
            reason: screen ? 'trial_screen' : 'trial_verify',
            strategyId: item.id, mode: mode.name, watchdog: false,
            infrastructure: protection.toJson(),
          );
          if (!started.running || started.strategyId != item.id || started.pid == null) {
            throw StateError(l.forkStrategyLaunchFailed);
          }
          await Future<void>.delayed(Duration(milliseconds: screen ? 1000 : 1500));
          if (cancelled()) return null;
          final first = await _verify(item.id, mode,
            timeoutMs: screen ? 2000 : 3500, expectedPid: started.pid, screenOnly: screen);
          if (cancelled()) return null;
          if (screen || tuneMode.controlRuns == 1 || first.error != null) return first;
          ZapretTrial second;
          try {
            second = await _verify(item.id, mode, expectedPid: started.pid);
          } catch (error) {
            final message = _errorMessage(error);
            if (error is HelperException && error.code == 'zapretConflict') {
              failure = message;
            }
            // Preserve the first round's actual measurements even when the
            // second round cannot run. Never present the mixed result as valid.
            second = ZapretTrial(item.id, mode, 0, 0, error: message,
                details: ['$controlLabel 2 · ${l.error}: $message']);
          }
          if (_cancelTrial || _launchBlocked) return null;
          return combineZapretControlRuns(first, second, runLabel: controlLabel);
        } catch (error) {
          final message = _errorMessage(error);
          if (error is HelperException && error.code == 'zapretConflict') {
            failure = message;
          }
          return ZapretTrial(item.id, mode, 0, 0, screenedOnly: screen, error: message);
        }
      }

      void record(ZapretTrial trial) {
        if (trial.error != null) {
          launchFailures++;
          lastLaunchFailure = trial.error;
        }
        final previous = results[trial.id];
        results[trial.id] = ZapretTrial(trial.id, trial.mode, trial.score, trial.delay,
          confirmed: trial.confirmed, passedTargets: trial.passedTargets,
          screenedOnly: trial.screenedOnly, error: trial.error,
          details: [
            if (trial.screenedOnly) '${l.forkScreenOnly}:',
            if (previous != null) ...previous.details,
            if (!trial.screenedOnly && tuneMode.controlRuns == 1) '$controlLabel:',
            if (!trial.screenedOnly && tuneMode.controlRuns == 2 &&
                !trial.details.contains('$controlLabel 1:')) '$controlLabel 1:',
            ...trial.details,
          ]);
        if (ref.mounted) {
          state = state.copyWith(trials: List.unmodifiable(
            shortlistZapretTrials(results.values, limit: results.length)));
        }
      }

      if (tuneMode.screenFirst) {
        for (var i = 0; i < strategies.length && !cancelled(); i++) {
          final item = strategies[i];
          final mode = item.supportsSplitMode ? selectedMode : ZapretMode.fullBypass;
          attempted++;
          state = state.copyWith(testProgress: '1/2 · $attempted/${strategies.length}: ${item.name}');
          final result = await probe(item, mode, screen: true);
          if (result != null) record(result);
        }
      }

      final candidates = tuneMode.screenFirst
          ? selectZapretFinalists(results.values).map((trial) => strategies.firstWhere((item) => item.id == trial.id)).toList()
          : strategies;
      finalists = candidates.length;
      for (final item in candidates) {
        if (cancelled()) break;
        final mode = item.supportsSplitMode ? selectedMode : ZapretMode.fullBypass;
        verified++;
        if (!tuneMode.screenFirst) attempted++;
        final stage = tuneMode.screenFirst ? '2/2 · ' : '';
        state = state.copyWith(testProgress: '$stage$verified/$finalists: ${item.name}');
        final result = await probe(item, mode, screen: false);
        if (result == null) break;
        record(result);
        if (tuneMode.shouldStop(result)) {
          earlyStop = true;
          break;
        }
      }
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
              await _client.restartZapret(reason: 'trial_restore', strategyId: original.strategyId!,
                mode: original.mode ?? 'fullBypass', debug: state.debugLogs,
                watchdog: state.watchdog, infrastructure: protection.toJson());
              if (protection.fingerprint == _infrastructure?.fingerprint) {
                _pendingInfrastructureRestart = false;
              }
            }
          }
        }
      } catch (error) {
        failure = '${l.forkRestoreStateFailed}: ${_errorMessage(error)}';
      }
      if (ref.mounted) {
        final interrupted = _cancelTrial || _launchBlocked;
        final ranked = shortlistZapretTrials(results.values, limit: results.length);
        final summary = interrupted ? l.forkTuneInterrupted :
            '${tuneMode.localizedLabel(l)} · ${tuneMode.screenFirst ? '${l.forkScreenOnly} $attempted/${strategies.length} · ' : ''}'
            '$controlLabel $verified/$finalists · ${l.forkErrors}: $launchFailures'
            '${earlyStop ? ' · ${l.forkTuneEarlyStop}' : ''}'
            '${lastLaunchFailure == null ? '' : '\n${l.forkLastError}: $lastLaunchFailure'}';
        String? historyError;
        if (!interrupted) {
          try {
            await saveZapretTuneRun(ZapretTuneRun(
              at: DateTime.now(),
              trials: List.unmodifiable(ranked),
              tuneMode: tuneMode,
              duration: runClock.elapsed,
              totalStrategies: strategies.length,
              summary: summary,
              failure: failure,
            ));
          } catch (_) {
            historyError = l.forkHistorySaveFailed;
          }
          if (failure == null) {
            try { await _saveTrials(ranked); } catch (_) {
              historyError = l.forkTuneSaveFailed;
            }
          }
        }
        if (!ref.mounted) return;
        state = state.copyWith(busy: false, clearTestProgress: true,
            testSummary: historyError == null ? summary : '$summary\n$historyError',
            trials: interrupted ? previousTrials : List.unmodifiable(ranked), error: failure);
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
      if (current.every((item) => item?.accepted == true)) {
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
        await _client.restartZapret(reason: 'fallback', strategyId: backup.id, mode: backup.mode.name,
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
              await _client.restartZapret(reason: 'fallback_restore', strategyId: originalId, mode: originalMode.name,
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
          message: AppLocalizations().forkCoreRecoveryFailed,
        );
      }
      if (!ref.mounted) return;
      await loadStrategies();
      await refresh();
      if (!state.available) {
        throw HelperException(
          code: 'helperZapretStillUnavailable',
          message: state.error ??
              AppLocalizations().forkHelperUpdatedCatalogMissing,
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
        message: AppLocalizations().forkHelperUnavailableReinstall,
      );
    }
  }

  String _errorMessage(Object error) => error is HelperException
      ? error.message
      : error.toString();
}
