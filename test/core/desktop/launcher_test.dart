import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('createCoreSessionId returns lowercase 128-bit hex', () {
    expect(createCoreSessionId(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('direct lease kills and confirms the owned process exit', () async {
    final process = _FakeProcess(pid: 42, exitCode: Future.value(0));
    String? executable;
    List<String>? arguments;
    final launcher = DirectCoreLauncher(
      startProcess: (value, valueArguments) async {
        executable = value;
        arguments = valueArguments;
        return process;
      },
      corePath: 'FlClashCore',
    );

    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );
    final result = await lease.stop(const Duration(seconds: 1));

    expect(lease.owner, CoreProcessOwner.direct);
    expect(lease.pid, 42);
    expect(executable, 'FlClashCore');
    expect(arguments, ['test-address']);
    expect(process.killed, isTrue);
    expect(
      result,
      const CoreProcessStopResult(stopped: true, exitConfirmed: true),
    );
  });

  test('direct lease reports an unconfirmed exit after timeout', () async {
    final process = _FakeProcess(pid: 42, exitCode: Completer<int>().future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final result = await lease.stop(Duration.zero);

    expect(result.stopped, isTrue);
    expect(result.exitConfirmed, isFalse);
  });

  test('direct lease keeps the headline of the crash report the Core last '
      'wrote', () async {
    final stderr = StreamController<List<int>>();
    final process = _FakeProcess(
      pid: 42,
      exitCode: Completer<int>().future,
      stderr: stderr.stream,
    );
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    stderr.add(utf8.encode('[ERROR] recovered '));
    stderr.add(utf8.encode('panic: boom\n'));
    await pumpEventQueue();
    expect(lease.crashHeadline, isNull);

    stderr.add(utf8.encode('SIGA'));
    stderr.add(utf8.encode('BRT: abort\nPC=0x1 m=0 sigcode=0\n\n'));
    stderr.add(utf8.encode('goroutine 1 gp=0x1 m=0 [running]:\n'));
    await pumpEventQueue();
    expect(lease.crashHeadline, 'SIGABRT: abort');
    await stderr.close();
  });

  test('direct lease handles split UTF-8 and malformed stderr before EOF', () async {
    final stderr = StreamController<List<int>>();
    final process = _FakeProcess(
      pid: 42, exitCode: Future.value(0), stderr: stderr.stream,
    );
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process, corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef', address: 'test-address',
    );
    final bytes = utf8.encode('panic: ошибка');
    stderr.add([0xff, 10]);
    stderr.add(bytes.sublist(0, 8));
    stderr.add(bytes.sublist(8));
    await stderr.close();
    await pumpEventQueue();
    expect(lease.crashHeadline, 'panic: ошибка');
  });

  test('direct lease can retry a failed kill', () async {
    final process = _FakeProcess(pid: 42, exitCode: Future.value(0))
      ..killError = StateError('kill failed');
    final lease = DirectCoreLease(sessionId: 'session', process: process);
    await expectLater(lease.stop(const Duration(seconds: 1)), throwsStateError);
    expect((await lease.stop(const Duration(seconds: 1))).exitConfirmed, isTrue);
  });

  test('direct lease rechecks exit after an unconfirmed timeout', () async {
    final exitCode = Completer<int>();
    final process = _FakeProcess(pid: 42, exitCode: exitCode.future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final firstResult = await lease.stop(Duration.zero);
    exitCode.complete(0);
    final secondResult = await lease.stop(const Duration(seconds: 1));

    expect(firstResult.exitConfirmed, isFalse);
    expect(secondResult.exitConfirmed, isTrue);
  });
}

class _FakeProcess implements Process {
  @override
  final int pid;

  @override
  final Future<int> exitCode;

  @override
  final Stream<List<int>> stdout = const Stream.empty();

  @override
  final Stream<List<int>> stderr;

  bool killed = false;
  Object? killError;

  _FakeProcess({
    required this.pid,
    required this.exitCode,
    this.stderr = const Stream.empty(),
  });

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final error = killError;
    killError = null;
    if (error != null) throw error;
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
