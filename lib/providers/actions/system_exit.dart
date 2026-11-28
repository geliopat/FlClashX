import 'dart:async';

typedef ExitStep = Future<void> Function();

final class SystemExitCoordinator {
  final Duration watchdogDuration;
  final Duration? cleanupTimeout;
  final Duration? windowCloseTimeout;
  final ExitStep closeWindow;
  final ExitStep closeCore;
  final ExitStep exitApplication;

  Future<void>? _operation;
  Future<void>? _applicationExitOperation;

  SystemExitCoordinator({
    required this.watchdogDuration,
    this.cleanupTimeout,
    this.windowCloseTimeout,
    required this.closeWindow,
    required this.closeCore,
    required this.exitApplication,
  });

  Future<void> exit({required ExitStep cleanup}) {
    final activeOperation = _operation;
    if (activeOperation != null) {
      return activeOperation;
    }
    final completion = Completer<void>();
    _operation = completion.future;
    unawaited(_run(cleanup).then<void>(
      (_) => completion.complete(),
      onError: (Object error, StackTrace stack) => completion.completeError(error, stack),
    ));
    return completion.future;
  }

  Future<void> _run(ExitStep cleanup) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runStep(ExitStep step, {Duration? timeout}) async {
      try {
        final operation = step();
        await (timeout == null ? operation : operation.timeout(timeout));
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    final watchdog = Timer(watchdogDuration, () {
      unawaited(_exitApplicationOnce().catchError((_) {}));
    });
    try {
      // Reserve time for the core close even when a preliminary step hangs.
      await runStep(cleanup, timeout: cleanupTimeout);
      await runStep(closeWindow, timeout: windowCloseTimeout);
      await runStep(closeCore);
    } finally {
      watchdog.cancel();
      await runStep(_exitApplicationOnce);
    }
    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  Future<void> _exitApplicationOnce() {
    final activeOperation = _applicationExitOperation;
    if (activeOperation != null) {
      return activeOperation;
    }
    final completion = Completer<void>();
    _applicationExitOperation = completion.future;
    unawaited(Future<void>.sync(exitApplication).then<void>(
      (_) => completion.complete(),
      onError: (Object error, StackTrace stack) => completion.completeError(error, stack),
    ));
    return completion.future;
  }
}
