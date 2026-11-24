import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final zapretControllerProvider =
    NotifierProvider<ZapretController, ZapretState>(ZapretController.new);

enum ZapretMode { strictSplit, fullBypass }

class ZapretState {
  static const _splitModeStrategyIds = <String>{
    'flowseal-alt',
    'flowseal-alt11',
    'flowseal-general',
    'flowseal-fake-tls-auto',
    'flowseal-simple-fake',
    'antidpi',
    'discord-light',
    'extsplit',
    'firstbyte',
    'ipfrag',
    'sites-light',
    'syndata',
    'tspu-max',
    'yt4k',
  };

  final bool available;
  final bool running;
  final bool busy;
  final int? pid;
  final int cleanedProcesses;
  final String? activeStrategyId;
  final String? activeEngine;
  final List<HelperZapretStrategy> strategies;
  final String selectedStrategyId;
  final ZapretMode mode;
  final String? error;

  const ZapretState({
    this.available = false,
    this.running = false,
    this.busy = false,
    this.pid,
    this.cleanedProcesses = 0,
    this.activeStrategyId,
    this.activeEngine,
    this.strategies = const [],
    this.selectedStrategyId = ZapretController.defaultStrategyId,
    this.mode = ZapretMode.fullBypass,
    this.error,
  });

  ZapretState copyWith({
    bool? available,
    bool? running,
    bool? busy,
    int? pid,
    bool clearPid = false,
    int? cleanedProcesses,
    String? activeStrategyId,
    bool clearActiveStrategy = false,
    String? activeEngine,
    bool clearActiveEngine = false,
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
      pid: clearPid ? null : pid ?? this.pid,
      cleanedProcesses: cleanedProcesses ?? this.cleanedProcesses,
      activeStrategyId: clearActiveStrategy
          ? null
          : activeStrategyId ?? this.activeStrategyId,
      activeEngine: clearActiveEngine ? null : activeEngine ?? this.activeEngine,
      strategies: strategies ?? this.strategies,
      selectedStrategyId: selectedStrategyId ?? this.selectedStrategyId,
      mode: mode ?? this.mode,
      error: clearError ? null : error ?? this.error,
    );
  }

  bool get supportsSplitMode {
    for (final strategy in strategies) {
      if (strategy.id != selectedStrategyId) continue;
      return _splitModeStrategyIds.contains(strategy.id);
    }
    return false;
  }
}

class ZapretController extends Notifier<ZapretState> {
  static const defaultStrategyId = 'flowseal-alt';
  static const _selectedStrategyPreferenceKey = 'zapret.strategyId';
  static const _modePreferenceKey = 'zapret.mode';
  static const _pollInterval = Duration(seconds: 3);
  static const _readinessTimeout = Duration(seconds: 3);

  final HelperClient _client = helperClient;
  Timer? _poller;
  var _refreshing = false;

  @override
  ZapretState build() {
    ref.onDispose(() => _poller?.cancel());
    if (Platform.isWindows) {
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
    if (!state.strategies.any((item) => item.id == strategyId)) {
      throw ArgumentError.value(strategyId, 'strategyId', 'Unknown Zapret strategy');
    }
    state = state.copyWith(selectedStrategyId: strategyId, clearError: true);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_selectedStrategyPreferenceKey, strategyId);
  }

  Future<void> setMode(ZapretMode mode) async {
    if (!state.supportsSplitMode) return;
    state = state.copyWith(mode: mode, clearError: true);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_modePreferenceKey, mode.name);
  }

  Future<void> refresh() async {
    if (!Platform.isWindows || _refreshing || state.busy) return;
    _refreshing = true;
    try {
      final response = await _client.zapretStatus();
      if (!ref.mounted) return;
      state = state.copyWith(
        available: state.strategies.isNotEmpty,
        running: response.running,
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        activeStrategyId: response.strategyId,
        activeEngine: response.engine,
        clearActiveStrategy: !response.running,
        clearActiveEngine: !response.running,
        clearError: state.strategies.isNotEmpty,
      );
    } on HelperException catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        available: error.code != 'zapretUnsupported',
        running: false,
        clearPid: true,
        error: error.message,
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        running: false,
        clearPid: true,
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
              mode: (state.supportsSplitMode ? state.mode : ZapretMode.fullBypass).name,
            )
          : await _client.stopZapret();
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        activeStrategyId: response.strategyId,
        activeEngine: response.engine,
        clearActiveStrategy: !response.running,
        clearActiveEngine: !response.running,
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
        mode: (state.supportsSplitMode ? state.mode : ZapretMode.fullBypass).name,
      );
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        activeStrategyId: response.strategyId,
        activeEngine: response.engine,
        clearActiveStrategy: !response.running,
        clearActiveEngine: !response.running,
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
