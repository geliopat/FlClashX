import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/file.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const _defaultPrefix = 'flutter.';

/// Stands in for the Windows and Linux stores, which truncate the file before
/// writing it (flutter/flutter#89211): same file and format, but each save
/// replaces it with a flushed sibling.
class AtomicFilePreferencesStore extends SharedPreferencesStorePlatform {
  AtomicFilePreferencesStore(this._path, {this.enableRecovery = false});

  final bool enableRecovery;

  final Future<String> _path;
  Future<Map<String, Object>>? _values;
  Future<bool> _lastWrite = Future.value(true);

  Future<Map<String, Object>> _read() {
    return _values ??= _load().catchError((Object error, StackTrace stack) {
      _values = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Map<String, Object> _decode(String raw) {
    final data = json.decode(raw);
    if (data is! Map) throw const FormatException('Preferences map required');
    return Map<String, Object>.from(data);
  }

  Future<Map<String, Object>> _load() async {
    final file = File(await _path);
    final backup = File('${file.path}.last-good');
    try {
      if (!await file.exists()) {
        if (enableRecovery && await backup.exists()) {
          throw const FormatException('Preferences missing');
        }
        return {};
      }
      final content = await file.readAsString();
      if (content.isEmpty && (!enableRecovery || !await backup.exists())) return {};
      return _decode(content);
    } catch (_) {
      if (!enableRecovery || !await backup.exists()) rethrow;
      final recovered = _decode(await backup.readAsString());
      if (await file.exists()) {
        // Preserve the exact damaged bytes, without exposing them in logs.
        final evidence = '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}';
        await file.copy(evidence);
      }
      await file.writeAsStringAtomically(jsonEncode(recovered));
      commonPrint.log('Recovered complete preferences store from backup',
        logLevel: LogLevel.warning);
      return recovered;
    }
  }

  Future<bool> _update(void Function(Map<String, Object> values) change) {
    final operation = _lastWrite.catchError((_) => false).then((_) async {
      final current = await _read();
      final next = Map<String, Object>.of(current);
      change(next);
      if (!await _write(json.encode(next), previous: json.encode(current))) return false;
      _values = Future.value(next);
      return true;
    });
    return _lastWrite = operation;
  }

  Future<bool> _write(String content, {required String previous}) async {
    final file = File(await _path);
    final backup = File('${file.path}.last-good');
    try {
      if (enableRecovery && !await backup.exists() && await file.exists()) {
        await backup.writeAsStringAtomically(previous);
      }
      await file.writeAsStringAtomically(content);
    } catch (error) {
      commonPrint.log(
        'Save preferences failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return false;
    }
    if (enableRecovery) {
      try {
        await backup.writeAsStringAtomically(content);
      } catch (_) {
        // The primary commit succeeded. Keep the previous backup and report
        // the reduced recovery guarantee without rolling back the live state.
        commonPrint.log('Preferences backup write failed', logLevel: LogLevel.warning);
      }
    }
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() {
    return getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final filter = parameters.filter;
    final values = await _read();
    return {
      for (final entry in values.entries)
        if (_matches(filter, entry.key)) entry.key: entry.value,
    };
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    return _update((values) => values[key] = value);
  }

  @override
  Future<bool> remove(String key) {
    return _update((values) => values.remove(key));
  }

  @override
  Future<bool> clear() {
    return clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    return _update(
      (values) =>
          values.removeWhere((key, _) => _matches(parameters.filter, key)),
    );
  }

  bool _matches(PreferencesFilter filter, String key) {
    return key.startsWith(filter.prefix) &&
        (filter.allowList?.contains(key) ?? true);
  }
}
