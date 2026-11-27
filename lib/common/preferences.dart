import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Preferences {
  static Preferences? _instance;
  var _store = ResolveOnce(_open);
  static const _lastGoodConfigKey = 'config.lastGood.v1';
  Future<bool> _configWrite = Future.value(true);

  Future<bool> get isInit async => await _store.value != null;

  Preferences._internal();

  static Future<SharedPreferences?> _open() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  Future<void> rebind() async {
    _store = ResolveOnce(_open);
    await _store.value;
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<int> getVersion() async {
    final preferences = await _store.value;
    return preferences?.getInt('version') ?? 0;
  }

  Future<void> setVersion(int version) async {
    final preferences = await _store.value;
    await preferences?.setInt('version', version);
  }

  Future<int> getUpgradeVersion() async {
    final preferences = await _store.value;
    return preferences?.getInt('upgradeVersion') ?? 0;
  }

  Future<void> setUpgradeVersion(int version) async {
    final preferences = await _store.value;
    await preferences?.setInt('upgradeVersion', version);
  }

  Future<bool> getLegacyImported() async {
    final preferences = await _store.value;
    return preferences?.getBool('legacyImported') ?? false;
  }

  Future<void> setLegacyImported() async {
    final preferences = await _store.value;
    await preferences?.setBool('legacyImported', true);
  }

  Future<bool> getPreChannelTipShown() async {
    final preferences = await _store.value;
    return preferences?.getBool('preChannelTipShown') ?? false;
  }

  Future<void> setPreChannelTipShown() async {
    final preferences = await _store.value;
    await preferences?.setBool('preChannelTipShown', true);
  }

  Future<void> saveShareState(SharedState shareState) async {
    final preferences = await _store.value;
    await preferences?.setString('sharedState', json.encode(shareState));
  }

  /// The md5 of the config.yaml the Core last accepted, which is also what
  /// the Android service applies when it starts without Flutter.
  Future<String?> getAppliedConfigMd5() async {
    final preferences = await _store.value;
    return preferences?.getString(appliedConfigMd5Key);
  }

  Future<void> saveAppliedConfigMd5(String? md5) async {
    final preferences = await _store.value;
    if (md5 == null) {
      await preferences?.remove(appliedConfigMd5Key);
    } else {
      await preferences?.setString(appliedConfigMd5Key, md5);
    }
  }

  Future<Map<String, Object?>?> getConfigMap() async {
    try {
      final preferences = await _store.value;
      final configString = preferences?.getString(configKey);
      if (configString == null) {
        if (preferences?.containsKey(_lastGoodConfigKey) != true) return null;
        throw const FormatException('missing primary config');
      }
      final decoded = json.decode(configString);
      if (decoded is! Map<String, Object?>) throw const FormatException('config');
      _validateConfig(decoded);
      return decoded;
    } catch (_) {
      commonPrint.log('Invalid settings JSON; checking last known good copy', logLevel: LogLevel.warning);
      try {
        final store = await _store.value;
        final raw = store?.getString(_lastGoodConfigKey);
        if (raw == null) return null;
        final map = jsonDecode(raw) as Map<String, Object?>;
        _validateConfig(map);
        commonPrint.log('Recovered last known good settings', logLevel: LogLevel.warning);
        return map;
      } catch (_) {
        return null;
      }
    }
  }

  Future<Map<String, Object?>?> getClashConfigMap() async {
    try {
      final preferences = await _store.value;
      final clashConfigString = preferences?.getString(clashConfigKey);
      if (clashConfigString == null) return null;
      return json.decode(clashConfigString);
    } catch (e) {
      commonPrint.log(
        'getClashConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> clearClashConfig() async {
    try {
      final preferences = await _store.value;
      await preferences?.remove(clashConfigKey);
      return;
    } catch (e) {
      commonPrint.log(
        'clearClashConfig error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return;
    }
  }

  static void _validateConfig(Map<String, Object?> map) {
    // Config.strictFromJson still salvages the nested app/theme settings.
    // Validate those explicitly before trusting a recovery copy.
    if (map.containsKey('appSettingProps')) {
      AppSettingProps.fromJson(Map<String, Object?>.from(map['appSettingProps'] as Map));
    }
    ThemeProps.fromJson(Map<String, Object?>.from(map['themeProps'] as Map));
    Config.strictFromJson(map);
  }

  Future<bool> saveConfig(Config config) {
    final operation = _configWrite.catchError((_) => false).then((_) async {
      final store = await _store.value;
      if (store == null) return false;
      final encoded = jsonEncode(config);
      _validateConfig(jsonDecode(encoded) as Map<String, Object?>);
      if (!await store.setString(configKey, encoded)) return false;
      return store.setString(_lastGoodConfigKey, encoded);
    });
    _configWrite = operation;
    return operation;
  }

  Future<SystemDnsRecord?> getSystemDnsRecord() async {
    try {
      final sharedPreferencesIns = await _store.value;
      final raw = sharedPreferencesIns?.getString(systemDnsRecordKey);
      if (raw == null) {
        return null;
      }
      return SystemDnsRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getSystemDnsRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveSystemDnsRecord(SystemDnsRecord record) async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.setString(
      systemDnsRecordKey,
      json.encode(record),
    );
  }

  Future<void> clearSystemDnsRecord() async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.remove(systemDnsRecordKey);
  }

  Future<bool> getSystemProxyApplied() async {
    final sharedPreferencesIns = await _store.value;
    return sharedPreferencesIns?.getBool(systemProxyAppliedKey) ?? false;
  }

  Future<bool> saveSystemProxyApplied(bool applied) async {
    final sharedPreferencesIns = await _store.value;
    if (sharedPreferencesIns == null) {
      return false;
    }
    return applied
        ? sharedPreferencesIns.setBool(systemProxyAppliedKey, true)
        : sharedPreferencesIns.remove(systemProxyAppliedKey);
  }

  Future<BootRecord?> getBootRecord() async {
    try {
      final sharedPreferencesIns = await _store.value;
      final raw = sharedPreferencesIns?.getString(bootRecordKey);
      if (raw == null) {
        return null;
      }
      return BootRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getBootRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveBootRecord(BootRecord record) async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.setString(bootRecordKey, json.encode(record));
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.clear();
  }
}

final preferences = Preferences();
