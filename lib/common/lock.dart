import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';

/// Keeps two processes off one data directory. Raising the running window is
/// the platform's job: LaunchServices reopen, GApplication activation, or the
/// app_links hand-off in the Windows runner.
class SingleInstanceLock {
  static SingleInstanceLock? _instance;
  RandomAccessFile? _accessFile;

  SingleInstanceLock._internal();

  factory SingleInstanceLock() {
    _instance ??= SingleInstanceLock._internal();
    return _instance!;
  }

  @visibleForTesting
  static Future<String> Function() resolvePath = () => appPath.lockFilePath;

  Future<bool> acquire() async {
    if (_accessFile != null) {
      return true;
    }
    RandomAccessFile? candidate;
    try {
      final lockFilePath = await resolvePath();
      final lockFile = File(lockFilePath);
      await lockFile.create();
      candidate = await lockFile.open(mode: FileMode.write);
      await candidate.lock();
      _accessFile = candidate;
      return true;
    } catch (e) {
      try {
        await candidate?.close();
      } catch (_) {
        // Keep the original lock error as the useful diagnostic.
      }
      commonPrint.log(
        'single instance lock acquire failed ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return false;
    }
  }

  @visibleForTesting
  Future<void> release() async {
    await _accessFile?.close();
    _accessFile = null;
  }
}

final singleInstanceLock = SingleInstanceLock();
