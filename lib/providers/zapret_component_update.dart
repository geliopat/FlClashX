import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/package.dart';
import 'package:fl_clash/features/update/asset.dart';
import 'package:fl_clash/features/update/download.dart';
import 'package:fl_clash/features/update/manifest.dart';
import 'package:fl_clash/features/update/manifest_signature.dart';
import 'package:fl_clash/providers/zapret_components.dart';
import 'package:path/path.dart' as p;

enum ZapretComponentUpdate { zapret2, flowseal, strategies, all }

const zapretPackageName = 'FlClashZ-zapret-components.json';
const _repository = 'geliopat/FlClashZ';
const _maxPackageBytes = 64 * 1024 * 1024;
const _prefix = 'zapret-components-';
final _releaseTag = RegExp(r'^zapret-components-v[0-9]+\.[0-9]+\.[0-9]+$');
final _hash = RegExp(r'^[a-f0-9]{64}$');
final _catalog = RegExp(r'^[a-f0-9]{40}:[a-f0-9]{40}$');
final _safeRelative = RegExp(r'^[a-zA-Z0-9_. ()/-]+$');

Directory get zapretComponentDirectory =>
    Directory(p.join(p.dirname(Platform.resolvedExecutable), 'zapret'));

File zapretUpdateMarker(Directory root) =>
    File(p.join(root.parent.path, 'zapret-update.pending'));

Directory _backupOf(Directory root) =>
    Directory(p.join(root.parent.path, 'zapret-update-backup'));

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Неверный формат пакета Zapret');
  }
  return value;
}

String _version(Map<String, dynamic> entry) => entry['version'] as String;

bool _safePath(String name) {
  if (!_safeRelative.hasMatch(name) ||
      name.split('/').any((s) => s.isEmpty || s == '.' || s == '..' ||
          s.endsWith('.') || s.endsWith(' '))) {
    return false;
  }
  // No arbitrary executables, command scripts, lists, Helper or app files.
  if (const {
    'winws2.exe', 'winws.exe', 'WinDivert.dll', 'WinDivert64.sys', 'cygwin1.dll',
  }.contains(name)) {
    return true;
  }
  if (!name.contains('/')) {
    return name.endsWith('.bin') ||
        (name.startsWith('zapret-') && name.endsWith('.lua'));
  }
  if (name.startsWith('strategies/zapret-') &&
      name.split('/').length == 2 && name.endsWith('.lua')) {
    return true;
  }
  return name.startsWith('strategies/imported/kinlay0/') &&
      name.split('/').length == 4 && name.endsWith('.bat');
}

Map<String, String> _files(Map<String, dynamic> component) {
  final files = _object(component['files']);
  if (files.isEmpty || files.length > 256) {
    throw const FormatException('Пустой или слишком большой каталог файлов');
  }
  final result = <String, String>{};
  final names = <String>{};
  for (final entry in files.entries) {
    if (!_safePath(entry.key) || !names.add(entry.key.toLowerCase()) ||
        entry.value is! String || !_hash.hasMatch(entry.value as String)) {
      throw FormatException('Недопустимый файл: ${entry.key}');
    }
    result[entry.key] = entry.value as String;
  }
  return result;
}

Map<String, dynamic> _components(Map<String, dynamic> manifest) {
  if (manifest['schema'] != 1 || manifest['catalogAbi'] is! String ||
      !_catalog.hasMatch(manifest['catalogAbi'] as String)) {
    throw const FormatException('Несовместимый каталог стратегий');
  }
  final result = _object(manifest['components']);
  if (result.length != zapretComponentNames.length ||
      !zapretComponentNames.every(result.containsKey)) {
    throw const FormatException('Неполный набор компонентов');
  }
  final names = <String>{};
  for (final name in zapretComponentNames) {
    for (final relative in _files(_object(result[name])).keys) {
      if (!names.add(relative.toLowerCase())) {
        throw FormatException('Повтор файла в каталоге: $relative');
      }
    }
  }
  return result;
}

bool _sameFiles(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

bool _sameComponent(Map<String, dynamic> a, Map<String, dynamic> b) =>
    _version(a) == _version(b) &&
    a['luaLibraryVersion'] == b['luaLibraryVersion'] &&
    _sameFiles(_files(a), _files(b));

String _numericVersion(String value) =>
    value.startsWith('v') ? value.substring(1) : value;

/// Returns only files belonging to the chosen, compatible components.
/// A changed compiled catalog or changed file set requires an app update.
Map<String, dynamic> planZapretComponentUpdate(
  Map<String, dynamic> oldManifest,
  Map<String, dynamic> newManifest,
  ZapretComponentUpdate kind,
) {
  final old = _components(oldManifest);
  final next = _components(newManifest);
  if (oldManifest['catalogAbi'] != newManifest['catalogAbi']) {
    throw StateError('Новый пакет требует обновления каталога Helper');
  }
  Map<String, dynamic> before(String name) => _object(old[name]);
  Map<String, dynamic> after(String name) => _object(next[name]);
  for (final name in zapretComponentNames) {
    final oldPaths = _files(before(name));
    final nextPaths = _files(after(name));
    if (oldPaths.length != nextPaths.length ||
        !oldPaths.keys.every(nextPaths.containsKey)) {
      throw StateError('Изменился набор файлов $name; требуется новая сборка');
    }
    if (name != 'Lua/BAT source' &&
        compareVersions(_numericVersion(_version(after(name))),
            _numericVersion(_version(before(name)))) < 0) {
      throw StateError('Понижение версии $name запрещено');
    }
  }
  if (compareVersions(
      _numericVersion(after('Lua/BAT source')['luaLibraryVersion'] as String),
      _numericVersion(before('Lua/BAT source')['luaLibraryVersion'] as String)) < 0) {
    throw StateError('Понижение версии общих Lua-библиотек запрещено');
  }
  final selected = switch (kind) {
    ZapretComponentUpdate.zapret2 => {'Zapret2', 'Lua/BAT source'},
    ZapretComponentUpdate.flowseal => {'Flowseal'},
    ZapretComponentUpdate.strategies => {'Lua/BAT source'},
    ZapretComponentUpdate.all => zapretComponentNames.toSet(),
  };
  // The whole bundle is tested as a set. Do not combine a changed component
  // with an unselected incompatible dependency.
  for (final name in zapretComponentNames.where((n) => !selected.contains(n))) {
    if (!_sameComponent(before(name), after(name))) {
      throw StateError('Пакет также меняет $name. Выбери «Обновить всё»');
    }
  }
  return {
    ...oldManifest,
    'components': {
      for (final name in zapretComponentNames)
        name: selected.contains(name) ? after(name) : before(name),
    },
  };
}

Future<Map<String, dynamic>> _readManifest(Directory root) async {
  final file = File(p.join(root.path, 'versions.json'));
  if (await file.length() > 1024 * 1024) {
    throw const FormatException('Слишком большой versions.json');
  }
  final manifest = _object(jsonDecode(await file.readAsString()));
  _components(manifest);
  return manifest;
}

Future<File> _existingFile(Directory root, String relative) async {
  if (!_safePath(relative) && relative != 'versions.json') {
    throw FormatException('Недопустимый путь: $relative');
  }
  final file = File(p.joinAll([root.path, ...relative.split('/')]));
  final canonicalRoot = await root.resolveSymbolicLinks();
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file ||
      !p.isWithin(canonicalRoot, await file.resolveSymbolicLinks())) {
    throw StateError('Файл отсутствует или находится вне Zapret: $relative');
  }
  return file;
}

Future<void> _verifyLocal(Directory root) async {
  final versions = await readZapretComponentVersions(root);
  if (versions.values.any((v) => v == 'неизвестно')) {
    throw StateError('Целостность установленного комплекта не подтверждена');
  }
}

class ZapretComponentPackage {
  ZapretComponentPackage(this.manifest, this.files);
  final Map<String, dynamic> manifest;
  final Map<String, List<int>> files;

  static ZapretComponentPackage decode(List<int> bytes) {
    if (bytes.length > _maxPackageBytes) {
      throw const FormatException('Слишком большой пакет Zapret');
    }
    final json = _object(jsonDecode(utf8.decode(bytes)));
    final manifest = _object(json['manifest']);
    final components = _components(manifest);
    final encoded = _object(json['files']);
    final result = <String, List<int>>{};
    for (final name in zapretComponentNames) {
      for (final entry in _files(_object(components[name])).entries) {
        final value = encoded[entry.key];
        if (value is! String) {
          throw FormatException('Нет файла ${entry.key}');
        }
        final data = base64.decode(value);
        if (data.isEmpty || sha256.convert(data).toString() != entry.value) {
          throw FormatException('SHA256 не совпадает: ${entry.key}');
        }
        result[entry.key] = data;
      }
    }
    if (encoded.length != result.length) {
      throw const FormatException('Лишние файлы в пакете');
    }
    return ZapretComponentPackage(manifest, result);
  }
}

/// The repository publishes independent, immutable, signed component packs.
/// Never execute an archive or BAT file obtained from a random upstream URL.
Future<ZapretComponentPackage> downloadZapretComponentPackage() async {
  if (updateManifestKeys.every((key) => key.isEmpty)) {
    throw StateError('В сборке не задан публичный ключ обновлений FlClashZ');
  }
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 45),
  ));
  final temp = await Directory.systemTemp.createTemp('flclashz-components-');
  try {
    final releases = await dio.get<List<dynamic>>(
      'https://api.github.com/repos/$_repository/releases?per_page=100',
    );
    final tags = [
      for (final release in releases.data ?? const [])
        if (release is Map && release['draft'] != true &&
            release['tag_name'] is String &&
            _releaseTag.hasMatch(release['tag_name'] as String))
          release['tag_name'] as String,
    ]..sort((a, b) => compareVersions(
        b.substring(_prefix.length + 1), a.substring(_prefix.length + 1)));
    if (tags.isEmpty) {
      throw StateError('Совместимые пакеты компонентов FlClashZ ещё не опубликованы');
    }
    final tag = tags.first;
    final base = 'https://github.com/$_repository/releases/download/$tag';
    final signed = await fetchManifestUpdate(
      dio, Uri.parse('$base/manifest.json'),
      currentVersion: '0.0.0', pre: false,
    );
    if (signed == null || signed['version'] != tag.substring(_prefix.length)) {
      throw StateError('Подпись или версия пакета не подтверждена');
    }
    final assets = signed['assets'] as List;
    final entry = assets.cast<Map>().firstWhere(
      (a) => a['name'] == zapretPackageName,
      orElse: () => throw StateError('В релизе нет пакета компонентов'),
    );
    final expected = (entry['sha256'] as String).toLowerCase();
    final downloader = UpdateDownloader(root: () async => temp, dio: dio);
    final file = await downloader.download(UpdateAsset(
      name: zapretPackageName,
      url: Uri.parse('$base/$zapretPackageName'),
      checksum: expected,
    ));
    if (await file.length() > _maxPackageBytes ||
        await sha256OfFile(file.path) != expected) {
      throw StateError('SHA256 пакета не совпадает или превышен лимит размера');
    }
    return ZapretComponentPackage.decode(await file.readAsBytes());
  } finally {
    dio.close(force: true);
    await temp.delete(recursive: true);
  }
}

/// Only existing allowlisted files are replaced, never lists or app binaries.
/// The Helper refuses to start the engine while the durable marker exists.
class ZapretComponentTransaction {
  ZapretComponentTransaction(this.root, this.package, this.kind);
  final Directory root;
  final ZapretComponentPackage package;
  final ZapretComponentUpdate kind;
  bool _prepared = false;

  Future<void> apply() async {
    final marker = zapretUpdateMarker(root);
    if (await marker.exists()) {
      throw StateError('Сначала восстанови незавершённое обновление');
    }
    await _verifyLocal(root);
    final old = await _readManifest(root);
    final next = planZapretComponentUpdate(old, package.manifest, kind);
    final oldComponents = _components(old);
    final nextComponents = _components(next);
    final changed = <String>{};
    for (final name in zapretComponentNames) {
      final previous = _files(_object(oldComponents[name]));
      final desired = _files(_object(nextComponents[name]));
      for (final entry in desired.entries) {
        if (previous[entry.key] != entry.value) changed.add(entry.key);
      }
    }
    if (changed.isEmpty && zapretComponentNames.every((name) =>
        _sameComponent(_object(oldComponents[name]), _object(nextComponents[name])))) {
      return;
    }
    final backup = _backupOf(root);
    if (await FileSystemEntity.type(backup.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Каталог резервной копии является ссылкой');
    }
    if (await backup.exists()) await backup.delete(recursive: true);
    await backup.create();
    try {
      for (final name in zapretComponentNames) {
        for (final relative in _files(_object(oldComponents[name])).keys) {
          final source = await _existingFile(root, relative);
          final destination = File(p.joinAll([backup.path, ...relative.split('/')]));
          await destination.parent.create(recursive: true);
          await source.copy(destination.path);
        }
      }
      await (await _existingFile(root, 'versions.json')).copy(
          p.join(backup.path, 'versions.json'));
      await _verifyLocal(backup);
      // Permission errors occur before replacing even a single live file.
      await marker.writeAsString('pending\n', flush: true);
      _prepared = true;
      for (final relative in changed) {
        await (await _existingFile(root, relative)).writeAsBytes(
            package.files[relative]!, flush: true);
      }
      await (await _existingFile(root, 'versions.json')).writeAsString(
          jsonEncode(next), flush: true);
      await _verifyLocal(root);
      await marker.delete();
    } catch (_) {
      if (_prepared) await rollback();
      rethrow;
    }
  }

  Future<void> rollback() async {
    if (!_prepared) return;
    await restoreZapretComponents(root);
    _prepared = false;
  }
}

Future<void> restoreZapretComponents(Directory root) async {
  final backup = _backupOf(root);
  if (await FileSystemEntity.type(backup.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Резервная копия компонентов отсутствует');
  }
  await _verifyLocal(backup);
  final manifest = await _readManifest(backup);
  final components = _components(manifest);
  final marker = zapretUpdateMarker(root);
  await marker.writeAsString('rollback\n', flush: true);
  for (final name in zapretComponentNames) {
    for (final relative in _files(_object(components[name])).keys) {
      final source = await _existingFile(backup, relative);
      final destination = await _existingFile(root, relative);
      await source.copy(destination.path);
    }
  }
  await (await _existingFile(backup, 'versions.json')).copy(
      (await _existingFile(root, 'versions.json')).path);
  await _verifyLocal(root);
  await marker.delete();
}
