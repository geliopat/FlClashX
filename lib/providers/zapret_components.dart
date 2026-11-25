import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

final zapretComponentsProvider =
    NotifierProvider<ZapretComponentsController, ZapretComponentState>(
      ZapretComponentsController.new,
    );

const zapretComponentNames = ['Zapret2', 'Flowseal', 'Lua/BAT source'];
const _unknown = 'неизвестно';
final _shaPattern = RegExp(r'^[a-f0-9]{64}$');
final _tagPattern = RegExp(r'^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.\-]+)?$');
final _commitPattern = RegExp(r'^[a-f0-9]{40}$');
final _relativePathPattern = RegExp(r'^[a-zA-Z0-9_. /-]+$');

class ZapretComponentState {
  const ZapretComponentState(this.versions, {
    this.installed = const {},
    this.checking = false,
  });
  final Map<String, String> versions;
  final Map<String, String> installed;
  final bool checking;

  String get summary =>
      'Zapret2 ${installed['Zapret2'] ?? _unknown} · '
      'Flowseal ${installed['Flowseal'] ?? _unknown} · '
      'Lua/BAT ${installed['Lua/BAT source'] ?? _unknown}';
}

bool _validHash(Object? value) =>
    value is String && _shaPattern.hasMatch(value);

/// Read actual bundled assets, independent of network or Helper readiness.
/// A missing, altered or unrecognized component is not assigned a version.
Future<Map<String, String>> readZapretComponentVersions(
  Directory directory,
) async {
  final installed = <String, String>{
    for (final name in zapretComponentNames) name: _unknown,
  };
  final Map<String, dynamic> components;
  try {
    final manifest = File(p.join(directory.path, 'versions.json'));
    if (await manifest.length() > 1024 * 1024) {
      return installed;
    }
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1 ||
        decoded['components'] is! Map<String, dynamic>) {
      return installed;
    }
    components = decoded['components'] as Map<String, dynamic>;
  } catch (_) {
    return installed;
  }

  for (final name in zapretComponentNames) {
    try {
      final item = components[name];
      if (item is! Map<String, dynamic>) continue;
      final version = item['version'];
      final files = item['files'];
      final isLua = name == 'Lua/BAT source';
      if (version is! String || files is! Map<String, dynamic> ||
          files.isEmpty || files.length > 256) {
        continue;
      }
      final required = switch (name) {
        'Zapret2' => ['winws2.exe', 'WinDivert.dll', 'WinDivert64.sys', 'cygwin1.dll'],
        'Flowseal' => ['winws.exe'],
        _ => ['zapret-lib.lua', 'zapret-auto.lua', 'zapret-antidpi.lua',
          'zapret-obfs.lua', 'strategies/zapret-lib.lua',
          'strategies/zapret-auto.lua', 'strategies/zapret-antidpi.lua',
          'strategies/zapret-obfs.lua'],
      };
      if (!required.every(files.containsKey)) continue;
      final luaVersion = item['luaLibraryVersion'];
      if (isLua) {
        if (!_commitPattern.hasMatch(version) ||
            luaVersion is! String || !_tagPattern.hasMatch(luaVersion)) {
          continue;
        }
      } else if (!_tagPattern.hasMatch(version) ||
          !_validHash(item['archiveSha256'])) {
        continue;
      }
      var valid = true;
      for (final entry in files.entries) {
        final relative = entry.key;
        final segments = relative.split('/');
        if (!_relativePathPattern.hasMatch(relative) ||
            segments.any((s) => s.isEmpty || s == '.' || s == '..') ||
            !_validHash(entry.value)) {
          valid = false;
          break;
        }
        final file = File(p.joinAll([directory.path, ...segments]));
        final root = await directory.resolveSymbolicLinks();
        final resolved = await file.resolveSymbolicLinks();
        if (!p.isWithin(root, resolved) ||
            (await sha256.bind(file.openRead()).first).toString() != entry.value) {
          valid = false;
          break;
        }
      }
      if (valid) {
        installed[name] = isLua
            ? '${version.substring(0, 12)} + Lua $luaVersion'
            : version;
      }
    } catch (_) {
      // Keep this component unknown without hiding other valid versions.
    }
  }
  return installed;
}

class ZapretComponentsController extends Notifier<ZapretComponentState> {
  static const _urls = {
    'Zapret2': 'https://api.github.com/repos/bol-van/zapret2/releases/latest',
    'Flowseal': 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest',
    'Lua/BAT source': 'https://api.github.com/repos/geliopat/zapret2-gui/commits/main',
  };

  @override
  ZapretComponentState build() {
    if (Platform.isWindows) {
      final timer = Timer.periodic(const Duration(hours: 24), (_) => unawaited(refresh()));
      ref.onDispose(timer.cancel);
      scheduleMicrotask(() => unawaited(refresh()));
    }
    return const ZapretComponentState({
      'Zapret2': 'установлено неизвестно · upstream не проверен',
      'Flowseal': 'установлено неизвестно · upstream не проверен',
      'Lua/BAT source': 'установлено неизвестно · upstream не проверен',
    });
  }

  Future<void> refresh() async {
    if (!Platform.isWindows || !ref.mounted || state.checking) return;
    state = ZapretComponentState(state.versions, installed: state.installed, checking: true);
    final directory = Directory(p.join(p.dirname(Platform.resolvedExecutable), 'zapret'));
    final installed = Map<String, String>.unmodifiable(
      await readZapretComponentVersions(directory),
    );
    if (!ref.mounted) return;
    final versions = <String, String>{
      for (final name in zapretComponentNames)
        name: 'в сборке ${installed[name]} · upstream проверяется',
    };
    state = ZapretComponentState(Map.unmodifiable(versions), installed: installed, checking: true);
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 15)));
    try {
      await Future.wait(_urls.entries.map((entry) async {
        try {
          final response = await dio.get<Map<String, dynamic>>(entry.value,
              options: Options(headers: const {'Accept': 'application/vnd.github+json'}));
          final value = response.data?[entry.key == 'Lua/BAT source' ? 'sha' : 'tag_name'];
          final upstream = value is String
              ? (entry.key == 'Lua/BAT source' && value.length >= 12 ? value.substring(0, 12) : value)
              : _unknown;
          versions[entry.key] = 'в сборке ${installed[entry.key]} · upstream $upstream';
        } catch (_) {
          versions[entry.key] = 'в сборке ${installed[entry.key]} · проверка недоступна';
        }
      }));
    } finally {
      dio.close(force: true);
      if (ref.mounted) {
        state = ZapretComponentState(Map.unmodifiable(versions), installed: installed);
      }
    }
  }
}
