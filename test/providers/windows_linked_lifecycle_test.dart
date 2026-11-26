import 'dart:io';

import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/preferences.dart';
import '../helpers/test_profiles.dart';
import 'setup_action_test.dart' show TestSetupAction, TestCommonAction;

class _Zapret extends ZapretController {
  _Zapret(this.events);
  final List<String> events;
  bool failStop = false;

  @override
  ZapretState build() => const ZapretState();

  @override
  Future<void> startAlongsideMihomo({bool force = false}) async {
    events.add('zapret:start:$force');
    state = state.copyWith(running: true);
  }

  @override
  Future<bool> stopAlongsideMihomo() async {
    events.add('zapret:stop');
    if (failStop) throw StateError('stop not confirmed');
    final wasRunning = state.running;
    state = state.copyWith(running: false);
    return wasRunning;
  }

  @override
  Future<bool> beginCoreRestart({bool repairHelper = false}) async {
    events.add('helper:prepare:$repairHelper');
    return stopAlongsideMihomo();
  }

  @override
  void endCoreRestart() => events.add('helper:release');
}

class _Setup extends TestSetupAction {
  _Setup(this.events);
  final List<String> events;

  @override
  Future<bool> setCoreRunning(bool running) async {
    events.add('mihomo:listener:$running');
    return super.setCoreRunning(running);
  }

  @override
  Future<bool> restartCoreRunning() async {
    events.add('mihomo:listener:restart');
    return super.restartCoreRunning();
  }
}

class _Core extends CoreAction {
  _Core(this.events);
  final List<String> events;

  @override
  bool get coreIsEmbedded => false;

  @override
  Future<void> initCore() async {
    events.add('mihomo:init');
  }

  @override
  Future<CoreLifecycleResult> restartLifecycle() async {
    events.add('mihomo:process:restart');
    return const CoreLifecycleResult(
      revision: 1, outcome: CoreLifecycleOutcome.applied,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows linked start, stop and restart are ordered', () async {
    await mockPreferences();
    final events = <String>[];
    final zapret = _Zapret(events);
    final container = ProviderContainer(overrides: [
      profilesProvider.overrideWith(TestProfiles.new),
      setupActionProvider.overrideWith(() => _Setup(events)),
      commonActionProvider.overrideWith(TestCommonAction.new),
      coreActionProvider.overrideWith(() => _Core(events)),
      zapretControllerProvider.overrideWith(() => zapret),
      safeModeProvider.overrideWithValue(false),
    ]);
    globalState.container = container;
    globalState.needInitStatus = true;
    addTearDown(container.dispose);
    container.read(initProvider.notifier).value = true;

    final setup = container.read(setupActionProvider.notifier);
    expect(await setup.setRunning(true, initialize: true), isTrue);
    expect(events, containsAllInOrder(['mihomo:listener:true', 'zapret:start:false']));
    events.clear();
    await setup.restartVpn();
    expect(events, containsAllInOrder(['zapret:stop', 'mihomo:listener:restart', 'zapret:start:true']));
    events.clear();
    expect(await container.read(coreActionProvider.notifier).restartCore(repairHelper: true), isTrue);
    expect(events, containsAllInOrder(['helper:prepare:true', 'zapret:stop', 'mihomo:process:restart', 'mihomo:init', 'mihomo:listener:true', 'helper:release', 'zapret:start:true']));
    events.clear();
    await setup.setRunning(false);
    expect(events, containsAllInOrder(['zapret:stop', 'mihomo:listener:false']));
    events.clear();
    expect(await container.read(coreActionProvider.notifier).restartCore(), isTrue);
    expect(events, isNot(contains('zapret:start:true')));
    expect(events, isNot(contains('mihomo:listener:true')));
    events.clear();
    expect(await setup.setTrayRunning(true), isTrue);
    expect(events, containsAllInOrder(['mihomo:listener:true', 'zapret:start:true']));
    events.clear();
    zapret.failStop = true;
    await expectLater(setup.setTrayRunning(false), throwsStateError);
    expect(events, containsAllInOrder(['zapret:stop', 'mihomo:listener:false']));
    expect(container.read(isStartProvider), isFalse);
    expect(container.read(zapretControllerProvider).running, isTrue);
    events.clear();
    zapret.failStop = false;
    expect(await setup.setTrayRunning(false), isTrue);
    expect(container.read(zapretControllerProvider).running, isFalse);
  }, skip: !Platform.isWindows);

  test('Windows refuses a full restart when Zapret stop fails', () async {
    await mockPreferences();
    final events = <String>[];
    final container = ProviderContainer(overrides: [
      profilesProvider.overrideWith(TestProfiles.new),
      setupActionProvider.overrideWith(() => _Setup(events)),
      coreActionProvider.overrideWith(() => _Core(events)),
      zapretControllerProvider.overrideWith(() => _Zapret(events)..failStop = true),
      safeModeProvider.overrideWithValue(false),
    ]);
    globalState.container = container;
    addTearDown(container.dispose);
    await expectLater(container.read(coreActionProvider.notifier).restartCore(), throwsStateError);
    expect(events, contains('zapret:stop'));
    expect(events, isNot(contains('mihomo:process:restart')));
  }, skip: !Platform.isWindows);
}
