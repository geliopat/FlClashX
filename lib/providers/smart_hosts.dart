import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/zapret.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const smartHostSourceUrls = {
  'malw': 'https://raw.githubusercontent.com/ImMALWARE/dns.malw.link/master/hosts',
  'geohide': 'https://dns.geohide.ru:8443/static/hosts/ru/hosts',
  'youtube': 'https://raw.githubusercontent.com/mqclass/zapret2-gui/main/lists/youtube-bad-nodes.txt',
};
const _maxBytes = 10 * 1024 * 1024;
const _maxEntries = 60000;
final _domain = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$');
final _youtubeNode = RegExp(r'^rr\d+---sn-[a-z0-9-]+\.googlevideo\.com$');

Map<String, String> parseSmartHosts(String content, {bool includeAdblock = false}) {
  final result = <String, String>{};
  for (final raw in const LineSplitter().convert(content)) {
    final parts = raw.split('#').first.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final ip = InternetAddress.tryParse(parts.first);
    if (ip == null || (!includeAdblock && (ip.isLoopback || ip.rawAddress.every((byte) => byte == 0)))) continue;
    for (final value in parts.skip(1)) {
      final domain = value.toLowerCase();
      if (domain.length > 253 || !_domain.hasMatch(domain) ||
          domain == 'localhost' || domain == 'ip6-localhost') {
        continue;
      }
      result.putIfAbsent(domain, () => ip.address);
      if (result.length >= _maxEntries) return result;
    }
  }
  return result;
}

Map<String, String> parseYoutubeNodes(String content) {
  final result = <String, String>{};
  for (final raw in const LineSplitter().convert(content)) {
    final host = raw.split('#').first.trim().toLowerCase();
    if (host.length <= 253 && _youtubeNode.hasMatch(host)) {
      result[host] = '127.0.0.2';
    }
    if (result.length >= _maxEntries) break;
  }
  return result;
}

bool protectedHostMatches(String pattern, String host) {
  final key = pattern.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final value = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (key == value) return true;
  if (key.startsWith('+.') || key.startsWith('*.') || key.startsWith('.')) {
    final suffix = key.startsWith('.') ? key.substring(1) : key.substring(2);
    if (value == suffix || value.endsWith('.$suffix')) return true;
  }
  if (key.contains('*') || key.contains('?')) {
    final escaped = RegExp.escape(key).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
    return RegExp('^$escaped' r'$').hasMatch(value);
  }
  return false;
}

Map<String, dynamic> mergeSmartHosts(
  Map<String, dynamic> config,
  Map<String, String> manual,
  Map<String, String> automatic,
) {
  if (automatic.isEmpty) return config;
  final raw = config['hosts'];
  if (raw != null && raw is! Map) return config;
  final hosts = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw as Map);
  final keys = [...hosts.keys, ...manual.keys];
  final exact = keys.map((key) => key.toLowerCase().replaceFirst(RegExp(r'\.$'), '')).toSet();
  final wildcard = keys.where((key) => key.contains('*') || key.contains('?') || key.startsWith('.') || key.startsWith('+.')).toList();
  for (final entry in automatic.entries) {
    if (exact.contains(entry.key) || wildcard.any((key) => protectedHostMatches(key, entry.key))) continue;
    hosts[entry.key] = entry.value;
  }
  return {...config, 'hosts': hosts};
}

String? youtubeCluster(String host) {
  if (!_youtubeNode.hasMatch(host)) return null;
  return host.substring(host.indexOf('---') + 3);
}

class CdnMeasurement {
  const CdnMeasurement(this.host, this.mbps, this.checkedAt, this.fast);
  final String host;
  final double mbps;
  final DateTime checkedAt;
  final bool fast;

  Map<String, dynamic> toJson() => {
    'host': host, 'mbps': mbps, 'checkedAt': checkedAt.millisecondsSinceEpoch, 'fast': fast,
  };

  factory CdnMeasurement.fromJson(Map value) => CdnMeasurement(
    value['host'] as String, (value['mbps'] as num).toDouble(),
    DateTime.fromMillisecondsSinceEpoch(value['checkedAt'] as int), value['fast'] == true,
  );
}

class SmartHostsState {
  const SmartHostsState({
    this.enabled = false,
    this.sources = const {},
    this.includeAdblock = false,
    this.autoUpdate = true,
    this.intervalHours = 24,
    this.customSources = const {},
    this.exclusions = const {},
    this.entries = const {},
    this.sourceCounts = const {},
    this.errors = const {},
    this.lastUpdate,
    this.updating = false,
    this.revision = 0,
    this.blockSlowCdn = false,
    this.autoCdn = false,
    this.cdnThreshold = 1.5,
    this.cdnTtlDays = 7,
    this.cdnChecking = false,
    this.cdnMeasurements = const [],
    this.cdnMessage,
  });
  final bool enabled;
  final Set<String> sources;
  final bool includeAdblock;
  final bool autoUpdate;
  final int intervalHours;
  final Map<String, String> customSources;
  final Set<String> exclusions;
  final Map<String, String> entries;
  final Map<String, int> sourceCounts;
  final Map<String, String> errors;
  final DateTime? lastUpdate;
  final bool updating;
  final int revision;
  final bool blockSlowCdn;
  final bool autoCdn;
  final double cdnThreshold;
  final int cdnTtlDays;
  final bool cdnChecking;
  final List<CdnMeasurement> cdnMeasurements;
  final String? cdnMessage;
}

final smartHostsProvider = NotifierProvider<SmartHostsController, SmartHostsState>(SmartHostsController.new);

class SmartHostsController extends Notifier<SmartHostsState> {
  static const _key = 'zapret.smartHosts.settings';
  final _rawCache = <String, String>{};
  final _errors = <String, String>{};
  final _client = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: false,
    responseType: ResponseType.stream,
  ));
  Timer? _timer;
  bool _loaded = false;
  bool _updating = false;
  bool _enabled = false;
  bool _adblock = false;
  bool _auto = true;
  int _hours = 24;
  int _revision = 0;
  DateTime? _last;
  Set<String> _sources = {};
  Set<String> _exclusions = {};
  Map<String, String> _custom = {};
  bool _blockSlow = false;
  bool _autoCdn = false;
  double _threshold = 1.5;
  int _ttlDays = 7;
  bool _cdnChecking = false;
  DateTime? _lastCdn;
  String? _cdnMessage;
  final _cdnMeasurements = <String, CdnMeasurement>{};

  @override
  SmartHostsState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _client.close(force: true);
    });
    if (Platform.isWindows) {
      scheduleMicrotask(_load);
      _timer = Timer.periodic(const Duration(minutes: 15), (_) {
        _publish();
        unawaited(_refreshIfDue());
        unawaited(_checkCdnIfDue());
      });
    }
    return const SmartHostsState();
  }

  Map<String, String> get _urls => {...smartHostSourceUrls, ..._custom};

  Future<File> _cacheFile(String id) async {
    final directory = Directory(p.join(await appPath.homeDirPath, 'smart-hosts'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, '${base64Url.encode(utf8.encode(id))}.txt'));
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonDecode(prefs.getString(_key) ?? '{}') as Map;
      _enabled = json['enabled'] == true;
      _adblock = json['adblock'] == true;
      _auto = json['auto'] != false;
      _hours = [6, 12, 24, 48, 168].contains(json['hours']) ? json['hours'] as int : 24;
      _sources = (json['sources'] as List? ?? []).whereType<String>().toSet();
      _exclusions = (json['exclusions'] as List? ?? []).whereType<String>().toSet();
      _custom = Map<String, String>.from(json['custom'] as Map? ?? {});
      _blockSlow = json['blockSlowCdn'] == true;
      _autoCdn = json['autoCdn'] == true;
      _threshold = (json['cdnThreshold'] as num? ?? 1.5).toDouble().clamp(0.5, 5.0).toDouble();
      _ttlDays = (json['cdnTtlDays'] as int? ?? 7).clamp(1, 30).toInt();
      final lastCdn = json['lastCdn'];
      _lastCdn = lastCdn is int ? DateTime.fromMillisecondsSinceEpoch(lastCdn) : null;
      for (final item in json['cdnMeasurements'] as List? ?? []) {
        try {
          final record = CdnMeasurement.fromJson(item as Map);
          final cluster = youtubeCluster(record.host);
          if (cluster != null) _cdnMeasurements[cluster] = record;
        } catch (_) {}
      }
      final last = json['last'];
      _last = last is int ? DateTime.fromMillisecondsSinceEpoch(last) : null;
      for (final id in _urls.keys) {
        final file = await _cacheFile(id);
        if (await file.exists() && await file.length() <= _maxBytes) {
          _rawCache[id] = await file.readAsString();
        }
      }
    } catch (error) {
      _errors['cache'] = error.toString();
    }
    _loaded = true;
    if (ref.mounted) {
      _publish();
      unawaited(_refreshIfDue());
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode({
      'enabled': _enabled,
      'adblock': _adblock,
      'auto': _auto,
      'hours': _hours,
      'sources': _sources.toList(),
      'custom': _custom,
      'exclusions': _exclusions.toList(),
      'last': _last?.millisecondsSinceEpoch,
      'blockSlowCdn': _blockSlow,
      'autoCdn': _autoCdn,
      'cdnThreshold': _threshold,
      'cdnTtlDays': _ttlDays,
      'lastCdn': _lastCdn?.millisecondsSinceEpoch,
      'cdnMeasurements': _cdnMeasurements.values.map((record) => record.toJson()).toList(),
    }));
  }

  void _publish() {
    if (!ref.mounted) return;
    final entries = <String, String>{};
    final counts = <String, int>{};
    _cdnMeasurements.removeWhere((_, record) => DateTime.now().difference(record.checkedAt) >= Duration(days: _ttlDays));
    for (final id in _urls.keys) {
      final raw = _rawCache[id] ?? (id == 'youtube' ? _bundledYoutubeNodes : '');
      final parsed = id == 'youtube'
          ? parseYoutubeNodes(raw)
          : parseSmartHosts(raw, includeAdblock: _adblock);
      counts[id] = parsed.length;
      if (!_enabled || !_sources.contains(id)) continue;
      for (final entry in parsed.entries) {
        if (_exclusions.any((key) => protectedHostMatches(key, entry.key))) continue;
        if (id == 'youtube' && _cdnMeasurements[youtubeCluster(entry.key)]?.fast == true) continue;
        if (entries.length >= _maxEntries) break;
        entries.putIfAbsent(entry.key, () => entry.value);
      }
    }
    if (_enabled && _blockSlow) {
      for (final entry in _cdnMeasurements.entries) {
        if (entry.value.fast) continue;
        for (final host in {entry.value.host, for (var rr = 1; rr <= 20; rr++) 'rr$rr---${entry.key}'}) {
          if (entries.length >= _maxEntries) break;
          if (_exclusions.any((key) => protectedHostMatches(key, host))) continue;
          entries.putIfAbsent(host, () => '127.0.0.2');
        }
      }
    }
    if (entries.length != state.entries.length ||
        entries.entries.any((entry) => state.entries[entry.key] != entry.value)) {
      _revision++;
    }
    state = SmartHostsState(
      enabled: _enabled,
      sources: Set.unmodifiable(_sources),
      includeAdblock: _adblock,
      autoUpdate: _auto,
      intervalHours: _hours,
      customSources: Map.unmodifiable(_custom),
      exclusions: Set.unmodifiable(_exclusions),
      entries: Map.unmodifiable(entries),
      sourceCounts: Map.unmodifiable(counts),
      errors: Map.unmodifiable(_errors),
      lastUpdate: _last,
      updating: _updating,
      revision: _revision,
      blockSlowCdn: _blockSlow,
      autoCdn: _autoCdn,
      cdnThreshold: _threshold,
      cdnTtlDays: _ttlDays,
      cdnChecking: _cdnChecking,
      cdnMeasurements: List.unmodifiable(_cdnMeasurements.values),
      cdnMessage: _cdnMessage,
    );
  }

  Future<void> configure({
    bool? enabled,
    String? source,
    bool? sourceEnabled,
    bool? includeAdblock,
    bool? autoUpdate,
    int? intervalHours,
    Map<String, String>? customSources,
    Set<String>? exclusions,
    bool? blockSlowCdn,
    bool? autoCdn,
    double? cdnThreshold,
    int? cdnTtlDays,
  }) async {
    if (!_loaded || _updating || _cdnChecking) return;
    _blockSlow = blockSlowCdn ?? _blockSlow;
    _autoCdn = autoCdn ?? _autoCdn;
    if (cdnThreshold != null && cdnThreshold != _threshold) {
      _threshold = cdnThreshold;
      _cdnMeasurements.clear();
      _lastCdn = null;
    }
    _ttlDays = cdnTtlDays ?? _ttlDays;
    _enabled = enabled ?? _enabled;
    _adblock = includeAdblock ?? _adblock;
    _auto = autoUpdate ?? _auto;
    _hours = intervalHours ?? _hours;
    if (source != null && _urls.containsKey(source)) {
      if (sourceEnabled == true) {
        _sources.add(source);
      } else {
        _sources.remove(source);
      }
    }
    if (customSources != null) {
      final validated = <String, String>{};
      for (final entry in customSources.entries) {
        final uri = Uri.tryParse(entry.value);
        if (entry.key.trim().isEmpty || entry.key.length > 100 ||
            smartHostSourceUrls.containsKey(entry.key) ||
            uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('Нужны уникальное имя и HTTPS URL без учётных данных');
        }
        validated[entry.key] = entry.value;
      }
      for (final id in _custom.keys) {
        if (_custom[id] != validated[id]) {
          _rawCache.remove(id);
          _sources.remove(id);
          final file = await _cacheFile(id);
          if (await file.exists()) await file.delete();
        }
      }
      _sources.addAll(validated.keys.where((id) => !_custom.containsKey(id) || _custom[id] != validated[id]));
      _custom = validated;
    }
    if (exclusions != null) _exclusions = exclusions;
    _publish();
    await _save();
    if (_enabled && _sources.any((id) => !_rawCache.containsKey(id))) {
      unawaited(refresh());
    }
    unawaited(_checkCdnIfDue());
  }

  Future<void> resetCdn() async {
    if (_cdnChecking) return;
    _cdnMeasurements.clear();
    _lastCdn = null;
    _cdnMessage = null;
    _publish();
    await _save();
  }

  Future<void> _checkCdnIfDue() async {
    if (!_loaded || !_enabled || !_autoCdn || _updating || _cdnChecking) return;
    if (_lastCdn == null || DateTime.now().difference(_lastCdn!) >= const Duration(hours: 24)) {
      await checkCdn();
    }
  }

  Future<void> checkCdn() async {
    if (!_loaded || _cdnChecking || _updating || ref.read(zapretControllerProvider).busy) return;
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      _cdnMessage = 'Ядро Mihomo недоступно';
      _publish();
      return;
    }
    _cdnChecking = true;
    _cdnMessage = 'Измерение DIRECT';
    _publish();
    try {
      final pid = ref.read(zapretControllerProvider).pid;
      final results = await ref.read(coreHandlerProvider).zapretCdnCheck();
      if (!ref.mounted) return;
      if (ref.read(zapretControllerProvider).pid != pid || ref.read(zapretControllerProvider).busy) {
        _cdnMessage = 'Стратегия изменилась во время проверки; результат отброшен';
        return;
      }
      final measured = <CdnMeasurement>[];
      final now = DateTime.now();
      for (final item in results) {
        final host = item['host'];
        final mbps = item['mbps'];
        if (host is! String || youtubeCluster(host) == null || mbps is! num ||
            !mbps.isFinite || mbps <= 0 || item['verdict'] != 'measured') continue;
        measured.add(CdnMeasurement(host, mbps.toDouble(), now, mbps >= _threshold));
      }
      final hasFast = measured.any((record) => record.fast);
      for (final record in measured) {
        if (!record.fast && !hasFast) continue;
        final cluster = youtubeCluster(record.host)!;
        final previous = _cdnMeasurements[cluster];
        if (previous != null && previous.checkedAt == now && previous.fast && !record.fast) continue;
        _cdnMeasurements[cluster] = record;
      }
      _lastCdn = now;
      _cdnMessage = measured.isEmpty
          ? 'Нет достоверных измерений; списки не изменены'
          : 'Измерено: ${measured.length}; быстрых: ${measured.where((record) => record.fast).length}';
      await _save();
    } catch (error) {
      _cdnMessage = 'Ошибка измерения: $error';
    } finally {
      _cdnChecking = false;
      _publish();
    }
  }

  Future<void> _refreshIfDue() async {
    if (!_loaded || !_enabled || !_auto || _updating) return;
    if (_last == null || DateTime.now().difference(_last!) >= Duration(hours: _hours)) {
      await refresh();
    }
  }

  Future<String> _download(String url) async {
    var uri = Uri.parse(url);
    for (var hop = 0; hop <= 5; hop++) {
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        throw const FormatException('Разрешены только HTTPS-источники');
      }
      final response = await _client.getUri<ResponseBody>(
        uri,
        options: Options(validateStatus: (_) => true),
      );
      final body = response.data;
      if (body == null) throw const FormatException('Пустой ответ');
      final code = response.statusCode ?? 0;
      if (code >= 300 && code < 400) {
        await body.stream.listen(null).cancel();
        final location = response.headers.value('location');
        if (location == null) throw const FormatException('Некорректное перенаправление');
        uri = uri.resolve(location);
        continue;
      }
      if (code != 200) {
        await body.stream.listen(null).cancel();
        throw StateError('HTTP $code');
      }
      final bytes = <int>[];
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > _maxBytes) {
          throw StateError('Источник превышает 10 МиБ');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    }
    throw StateError('Слишком много перенаправлений');
  }

  Future<void> refresh() async {
    if (!_loaded || !_enabled || _updating || _cdnChecking || _sources.isEmpty) return;
    _updating = true;
    _publish();
    try {
      for (final entry in _urls.entries) {
        if (!_sources.contains(entry.key)) continue;
        try {
          final raw = await _download(entry.value).timeout(const Duration(seconds: 90));
          final valid = entry.key == 'youtube'
              ? parseYoutubeNodes(raw)
              : parseSmartHosts(raw, includeAdblock: true);
          if (valid.isEmpty) throw StateError('Источник не содержит корректных записей');
          final file = await _cacheFile(entry.key);
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(raw, flush: true);
          await temp.rename(file.path);
          _rawCache[entry.key] = raw;
          _errors.remove(entry.key);
        } catch (error) {
          _errors[entry.key] = error.toString();
        }
      }
      _last = DateTime.now();
      await _save();
    } finally {
      _updating = false;
      _publish();
    }
  }
}

const _bundledYoutubeNodes = '''
rr1---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr2---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr3---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr4---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr5---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr6---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr7---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr8---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr9---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr10---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr11---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr12---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr13---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr14---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr15---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr16---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr17---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr18---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr19---sn-gvnuxaxjvh-n8ml.googlevideo.com
rr20---sn-gvnuxaxjvh-n8ml.googlevideo.com
''';
