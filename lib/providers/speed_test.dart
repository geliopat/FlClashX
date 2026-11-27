import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SpeedTestService { cloudflare, yandex, custom }

const speedTestDefaultDownload = 'https://speed.cloudflare.com/__down?bytes=16777216';
const speedTestDefaultUpload = 'https://speed.cloudflare.com/__up';

const delayTestPresets = <String, String>{
  'Google': defaultTestUrl,
  'Cloudflare': 'https://cp.cloudflare.com/generate_204',
  'Microsoft': 'https://www.msftconnecttest.com/connecttest.txt',
  'Apple': 'https://captive.apple.com/hotspot-detect.html',
};

bool validTestEndpoint(String text) {
  final uri = Uri.tryParse(text);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty && uri.userInfo.isEmpty && !uri.hasFragment;
}

class SpeedTestSettings {
  const SpeedTestSettings({
    this.service = SpeedTestService.cloudflare,
    this.downloadUrl = speedTestDefaultDownload,
    this.uploadUrl = speedTestDefaultUpload,
  });
  final SpeedTestService service;
  final String downloadUrl;
  final String uploadUrl;
  SpeedTestSettings copyWith({
    SpeedTestService? service, String? downloadUrl, String? uploadUrl,
  }) => SpeedTestSettings(
    service: service ?? this.service,
    downloadUrl: downloadUrl ?? this.downloadUrl,
    uploadUrl: uploadUrl ?? this.uploadUrl,
  );
}

final speedTestSettingsProvider =
    NotifierProvider<SpeedTestSettingsController, SpeedTestSettings>(
      SpeedTestSettingsController.new,
    );

class SpeedTestSettingsController extends Notifier<SpeedTestSettings> {
  int _revision = 0;
  @override
  SpeedTestSettings build() {
    unawaited(_load());
    return const SpeedTestSettings();
  }

  Future<void> _load() async {
    final revision = _revision;
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted || revision != _revision) return;
    state = SpeedTestSettings(
      service: SpeedTestService.values.asNameMap()[
        prefs.getString('speedTest.service')
      ] ?? SpeedTestService.cloudflare,
      downloadUrl: prefs.getString('speedTest.download') ?? speedTestDefaultDownload,
      uploadUrl: prefs.getString('speedTest.upload') ?? speedTestDefaultUpload,
    );
  }

  Future<void> set(SpeedTestSettings settings) async {
    if (!validTestEndpoint(settings.downloadUrl) ||
        !validTestEndpoint(settings.uploadUrl)) return;
    _revision++;
    state = settings;
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final latest = state;
    await prefs.setString('speedTest.service', latest.service.name);
    await prefs.setString('speedTest.download', latest.downloadUrl);
    await prefs.setString('speedTest.upload', latest.uploadUrl);
  }
}

bool speedTestableProxy(Proxy proxy) =>
    GroupTypeExtension.getGroupType(proxy.type) == null &&
    !GroupType.values.any((group) => group.value == proxy.type.toLowerCase()) &&
    proxy.name.isNotEmpty &&
    (proxy.name == 'DIRECT' ||
      !{'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'}
          .contains(proxy.name.toUpperCase())) &&
    (proxy.name == 'DIRECT' || proxy.type.toLowerCase() != 'direct');

Set<String> speedTestTargets(List<Group> groups) {
  final groupNames = groups.map((group) => group.name).toSet();
  return {
    for (final group in groups)
      for (final proxy in group.all)
        if (!groupNames.contains(proxy.name) && speedTestableProxy(proxy))
          proxy.name,
    'DIRECT',
  };
}

class SpeedTestState {
  const SpeedTestState({this.pending = const {}, this.running,
    this.results = const {}, this.busy = false});
  final Set<String> pending;
  final String? running;
  final Map<String, ProxySpeedResult> results;
  final bool busy;
}

final speedTestProvider = NotifierProvider<SpeedTestController, SpeedTestState>(
  SpeedTestController.new,
);

class SpeedTestController extends Notifier<SpeedTestState> {
  int _generation = 0;
  @override
  SpeedTestState build() {
    ref.listen(currentProfileIdProvider, (_, _) => _invalidate());
    ref.listen(coreStatusProvider, (_, status) {
      if (status != CoreStatus.connected) _invalidate();
    });
    ref.listen(speedTestSettingsProvider, (_, _) => _invalidate());
    return const SpeedTestState();
  }

  void _invalidate() {
    _generation++;
    state = SpeedTestState(busy: state.busy);
  }

  Future<void> testAll() => _run(speedTestTargets(ref.read(groupsProvider)));

  Future<void> testProxy(Proxy proxy) async {
    if (!speedTestableProxy(proxy)) return;
    if (ref.read(groupsProvider).any((group) => group.name == proxy.name)) return;
    await _run({proxy.name});
  }

  Future<void> _run(Set<String> targets) async {
    if (targets.isEmpty || state.busy ||
        ref.read(coreStatusProvider) != CoreStatus.connected) return;
    final settings = ref.read(speedTestSettingsProvider);
    final generation = ++_generation;
    final pending = {...targets};
    final results = {...state.results};
    state = SpeedTestState(pending: {...pending}, results: {...results}, busy: true);
    try {
      for (final name in targets) {
        if (!ref.mounted || generation != _generation) break;
        state = SpeedTestState(pending: {...pending}, running: name,
            results: {...results}, busy: true);
        ProxySpeedResult? result;
        try {
          result = await ref.read(coreHandlerProvider).speedTest(
            ProxySpeedRequest(
              proxyName: name,
              service: name == 'DIRECT' ? 'yandex' : settings.service.name,
              downloadUrl: settings.downloadUrl,
              uploadUrl: settings.uploadUrl,
            ),
          );
        } catch (_) {
          result = null;
        }
        if (!ref.mounted || generation != _generation) break;
        pending.remove(name);
        results[name] = result ?? const ProxySpeedResult(
          downloadError: 'failed', uploadError: 'failed',
        );
        state = SpeedTestState(pending: {...pending}, results: {...results}, busy: true);
      }
    } finally {
      if (ref.mounted) state = SpeedTestState(results: state.results);
    }
  }
}
