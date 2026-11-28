part of '../action.dart';

@Riverpod(keepAlive: true)
class SystemAction extends _$SystemAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  SystemExitCoordinator? _exitCoordinator;
  Future<void>? _restartRequest;
  bool get isExiting => _exitCoordinator != null;

  @override
  void build() {}

  Future<List<Package>> getPackages() async {
    ref.read(packagesProvider.notifier).value = await app?.getPackages() ?? [];
    return ref.read(packagesProvider);
  }

  Future<bool> isInstalledAppsPermissionGranted() async {
    return await app?.isInstalledAppsPermissionGranted() ?? true;
  }

  Future<bool> requestInstalledAppsPermission() async {
    return await app?.requestInstalledAppsPermission() ?? false;
  }

  Future<void> handleExit([bool needSave = true]) {
    final coordinator = _exitCoordinator ??= SystemExitCoordinator(
      watchdogDuration: exitWatchdogDuration,
      cleanupTimeout: system.isWindows ? const Duration(seconds: 20) : null,
      windowCloseTimeout: system.isWindows ? const Duration(seconds: 3) : null,
      closeWindow: closeWindow,
      closeCore: closeCore,
      exitApplication: exitApplication,
    );
    return coordinator.exit(cleanup: () => cleanupExitResources(needSave));
  }

  /// The new copy waits for this one to quit, as only one may run.
  Future<void> handleRestart() {
    if (isExiting) return Future.value();
    return _restartRequest ??= _scheduleRestart().whenComplete(() {
      _restartRequest = null;
    });
  }

  Future<void> _scheduleRestart() async {
    try {
      await relaunchSelf();
    } catch (error) {
      commonPrint.log(
        'Restart failed: ${compactError(error)}',
        logLevel: LogLevel.error,
      );
      return;
    }
    await handleExit();
  }

  @protected
  Future<void> relaunchSelf() => relaunchSelfAfterExit();

  @protected
  Duration get exitWatchdogDuration =>
      system.isWindows ? const Duration(seconds: 40) : const Duration(seconds: 3);

  @protected
  Future<void> cleanupExitResources(bool needSave) async {
    ref.read(setupActionProvider.notifier).quiesceForExit();

    // Release OS settings immediately, even if the core or Helper is hung.
    // The proxy queue closes synchronously to further starts before its
    // pending OS calls finish.
    final network = Future.wait<void>([
      if (systemDnsCoordinator != null) systemDnsCoordinator!.shutdown(),
      ?systemProxyQueue?.close(),
    ]);
    final save = needSave ? _savePreferencesSafely() : null;
    final tray = trayPort;

    await Future.wait<void>([
      network.then<void>((_) {}),
      _cleanupStep('Zapret', () async {
        if (system.isWindows) {
          await ref.read(zapretControllerProvider.notifier).stopAlongsideMihomo();
        }
      }),
      _cleanupStep('Traffic history', () async {
        if (!system.isWindows) return;
        final history = ref.read(trafficHistoryProvider);
        if (ref.read(coreStatusProvider) == CoreStatus.connected) {
          try {
            await ref.read(commonActionProvider.notifier).updateTraffic()
                .timeout(const Duration(seconds: 3));
          } on TimeoutException {
            commonPrint.log('Final traffic sample timed out', logLevel: LogLevel.warning);
          }
        }
        await history.flush();
      }),
      if (tray != null) _cleanupStep('Tray', tray.shutdown),
      ?save,
      drainDatabaseWrites(),
      fileLogger.dispose(),
      if (system.isWindows) appFileLogger.flush(),
      if (system.isWindows) zapretFileLogger.flush(),
      if (system.isWindows) crashFileLogger.flush(),
      if (system.isWindows) recoveryJournal.flush(),
    ]);
    await bootGuard.markClosed();
  }

  Future<void> _cleanupStep(String name, Future<void> Function() step) async {
    try {
      await step();
    } catch (error) {
      commonPrint.log(
        '$name exit cleanup failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }
  }

  Future<void> _savePreferencesSafely() async {
    try {
      await savePreferences();
    } catch (error) {
      commonPrint.log(
        'Preferences save failed: ${compactError(error)}',
        logLevel: LogLevel.error,
      );
    }
  }

  @protected
  Future<void> savePreferences() async {
    final port = windowPort;
    if (port != null) {
      try {
        final current = ref.read(windowSettingProvider);
        final geometry = await port.captureNormalGeometry(current);
        if (geometry != null) {
          ref.read(windowSettingProvider.notifier).value = geometry;
        }
      } catch (error) {
        commonPrint.log(
          'Window geometry capture failed: ${compactError(error)}',
          logLevel: LogLevel.warning,
        );
      }
    }
    if (!await preferences.saveConfig(ref.read(configProvider))) {
      throw StateError('Unable to save application preferences');
    }
    if (savesSharedState) {
      // The save AndroidManager debounces would die with the engine.
      debouncer.cancel(FunctionTag.saveSharedFile);
      await ref.read(vpnOptionsProvider.future);
      await preferences.saveShareState(ref.read(sharedStateProvider));
    }
  }

  /// A Quick Settings start without Flutter reads the VPN options from it.
  @protected
  bool get savesSharedState => system.isAndroid;

  @protected
  Future<void> closeWindow() async {
    await windowPort?.close();
  }

  @protected
  Future<void> closeCore() async {
    await _core.close();
    commonPrint.log('exit');
  }

  @protected
  Future<void> exitApplication() async {
    await system.exit();
    windowPort?.forceExit();
  }

  Future<void> handleClose([bool exit = true]) async {
    if (ref.read(appSettingProvider).minimizeOnExit || !exit) {
      if (system.isDesktop) {
        await _savePreferencesSafely();
      }
      await system.back();
      await windowPort?.hide();
    } else {
      await handleExit();
    }
  }

  Future<void> updateVisible() async {
    await windowPort?.toggle();
  }

  /// From the tray or a hotkey, which have nowhere to ask before taking the
  /// switch over from the subscription.
  void updateTun() {
    ref
        .read(managedSettingsActionProvider.notifier)
        .takeOverIfLocked('clash.tun.enable');
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    if (!ref.read(systemProxyAllowedProvider)) {
      return;
    }
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: !state.systemProxy));
  }

  Future<void> copyProxyEnv() async {
    final port = ref.read(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    await Clipboard.setData(
      ClipboardData(text: proxyEnvCommand(port, isWindows: system.isWindows)),
    );
  }

  Future<void> updateTray() async {
    await trayPort?.update(
      trayState: ref.read(trayStateProvider),
      traffic: ref.read(
        trafficsProvider.select(
          (state) => state.list.safeLast(const Traffic()),
        ),
      ),
      read: globalState.container.read,
    );
  }

  Future<void> updateLocalIp() async {
    ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    ref.read(localIpProvider.notifier).value = await getLocalIpAddress();
  }
}
