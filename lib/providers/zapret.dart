import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final zapretControllerProvider =
    NotifierProvider<ZapretController, ZapretState>(ZapretController.new);

class ZapretState {
  final bool available;
  final bool running;
  final bool busy;
  final int? pid;
  final int cleanedProcesses;
  final String? error;

  const ZapretState({
    this.available = true,
    this.running = false,
    this.busy = false,
    this.pid,
    this.cleanedProcesses = 0,
    this.error,
  });

  ZapretState copyWith({
    bool? available,
    bool? running,
    bool? busy,
    int? pid,
    bool clearPid = false,
    int? cleanedProcesses,
    String? error,
    bool clearError = false,
  }) {
    return ZapretState(
      available: available ?? this.available,
      running: running ?? this.running,
      busy: busy ?? this.busy,
      pid: clearPid ? null : pid ?? this.pid,
      cleanedProcesses: cleanedProcesses ?? this.cleanedProcesses,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class ZapretController extends Notifier<ZapretState> {
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
        if (ref.mounted) unawaited(refresh());
      });
      _poller = Timer.periodic(_pollInterval, (_) {
        if (ref.mounted) unawaited(refresh());
      });
    }
    return const ZapretState();
  }

  Future<void> refresh() async {
    if (!Platform.isWindows || _refreshing || state.busy) return;
    _refreshing = true;
    try {
      final response = await _client.zapretStatus();
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
        clearError: true,
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
          ? await _client.startZapret()
          : await _client.stopZapret();
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
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
  /// before it starts a fresh winws2.exe.
  Future<void> restart() async {
    if (!Platform.isWindows || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _requireHelper();
      final response = await _client.restartZapret();
      if (!ref.mounted) return;
      state = state.copyWith(
        available: true,
        running: response.running,
        pid: response.pid,
        clearPid: !response.running,
        cleanedProcesses: response.cleanedProcesses,
      );
    } catch (error) {
      state = state.copyWith(error: _errorMessage(error));
      rethrow;
    } finally {
      state = state.copyWith(busy: false);
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
