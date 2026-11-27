import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/speed_test.dart' show validTestEndpoint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NetworkProbeSettings {
  const NetworkProbeSettings({
    this.ipSource = 'auto',
    this.customIpUrl = 'https://api.ipify.org?format=json',
    this.ipFallback = true,
    this.ipTimeout = 6,
    this.serviceTimeout = 10,
  });
  final String ipSource;
  final String customIpUrl;
  final bool ipFallback;
  final int ipTimeout;
  final int serviceTimeout;

  ({String source, String url, bool fallback, int timeout}) get ipKey =>
      (source: ipSource, url: customIpUrl, fallback: ipFallback, timeout: ipTimeout);

  String? get selectedIpUrl => ipSource == 'custom' ? customIpUrl : selectableIpSources[ipSource];
  static const timeouts = [3, 5, 6, 10, 15, 20, 30];

  NetworkProbeSettings copyWith({
    String? ipSource, String? customIpUrl, bool? ipFallback,
    int? ipTimeout, int? serviceTimeout,
  }) => NetworkProbeSettings(
    ipSource: ipSource ?? this.ipSource,
    customIpUrl: customIpUrl ?? this.customIpUrl,
    ipFallback: ipFallback ?? this.ipFallback,
    ipTimeout: ipTimeout ?? this.ipTimeout,
    serviceTimeout: serviceTimeout ?? this.serviceTimeout,
  );

  Map<String, Object> toJson() => {
    'source': ipSource, 'customUrl': customIpUrl, 'fallback': ipFallback,
    'ipTimeout': ipTimeout, 'serviceTimeout': serviceTimeout,
  };

  static NetworkProbeSettings decode(String? raw) {
    if (raw == null) return const NetworkProbeSettings();
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return const NetworkProbeSettings();
      final source = map['source'];
      final custom = map['customUrl'];
      return NetworkProbeSettings(
        ipSource: source is String && (source == 'auto' || source == 'custom' ||
            selectableIpSources.containsKey(source)) ? source : 'auto',
        customIpUrl: custom is String && validTestEndpoint(custom)
            ? custom : const NetworkProbeSettings().customIpUrl,
        ipFallback: map['fallback'] is bool ? map['fallback'] as bool : true,
        ipTimeout: timeouts.contains(map['ipTimeout']) ? map['ipTimeout'] as int : 6,
        serviceTimeout: timeouts.contains(map['serviceTimeout']) ? map['serviceTimeout'] as int : 10,
      );
    } catch (_) {
      return const NetworkProbeSettings();
    }
  }
}

final networkProbeSettingsProvider = NotifierProvider<NetworkProbeSettingsController, NetworkProbeSettings>(
    NetworkProbeSettingsController.new);

class NetworkProbeSettingsController extends Notifier<NetworkProbeSettings> {
  static const _key = 'networkTests.probes.v1';
  int _revision = 0;
  Future<void> _writes = Future.value();

  @override
  NetworkProbeSettings build() {
    unawaited(_load());
    return const NetworkProbeSettings();
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || revision != _revision) return;
      final next = NetworkProbeSettings.decode(prefs.getString(_key));
      if (next.ipKey != state.ipKey || next.serviceTimeout != state.serviceTimeout) state = next;
    } catch (_) {
      // A missing preferences backend must not stop the existing probes.
    }
  }

  Future<void> set(NetworkProbeSettings next) {
    final normalized = NetworkProbeSettings.decode(jsonEncode(next.toJson()));
    _revision++;
    state = normalized;
    final encoded = jsonEncode(normalized.toJson());
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_key, encoded);
      } catch (_) {}
    });
    return _writes;
  }
}
