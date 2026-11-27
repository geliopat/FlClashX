import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'constant.dart';
import 'system.dart';
import 'print.dart';
import 'windows_startup.dart';
import 'package:fl_clash/enum/enum.dart';

class AutoLaunch {
  static AutoLaunch? _instance;

  AutoLaunch._internal() {
    launcher.setup(
      appName: appSystemName,
      appPath: Platform.resolvedExecutable,
    );
  }

  factory AutoLaunch() {
    _instance ??= AutoLaunch._internal();
    return _instance!;
  }

  @visibleForTesting
  static LaunchAtStartup launcher = launchAtStartup;

  bool get _scheduled => Platform.isWindows && !kDebugMode;
  WindowsStartupTask get _task => WindowsStartupTask(name: appSystemName, executable: Platform.resolvedExecutable);
  Future<void> _updates = Future.value();

  Future<bool> get isEnable async {
    if (_scheduled) return _task.isEnabled();
    return launcher.isEnabled();
  }

  Future<bool> enable() async {
    if (!_scheduled) return launcher.enable();
    if (!await _task.enable()) return false;
    if (await launcher.isEnabled() && !await launcher.disable()) return false;
    return true;
  }

  Future<bool> disable() async {
    if (!_scheduled) return launcher.disable();
    if (!await _task.disable()) return false;
    return !await launcher.isEnabled() || await launcher.disable();
  }

  Future<void> updateStatus(bool isAutoLaunch) {
    if (kDebugMode) return Future.value();
    _updates = _updates.then((_) async {
      try {
        // Reconcile on Windows even when enabled: repair the executable path
        // after an install/update or a move, and migrate the owned Run entry.
        if (!_scheduled && await isEnable == isAutoLaunch) return;
        final success = isAutoLaunch ? await enable() : await disable();
        commonPrint.log('Autostart reconciliation: ${success ? 'ok' : 'failed'}',
          logLevel: success ? LogLevel.info : LogLevel.warning);
      } catch (_) {
        commonPrint.log('Autostart reconciliation failed', logLevel: LogLevel.warning);
      }
    });
    return _updates;
  }
}

final autoLaunch = system.isDesktop && !safeModeBuild ? AutoLaunch() : null;
