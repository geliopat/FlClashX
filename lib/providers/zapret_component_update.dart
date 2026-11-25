import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

enum ZapretComponent { zapret2, flowseal, strategies, all }

const _catalogUrl = 'https://raw.githubusercontent.com/geliopat/FlClashZ/fix/zapret2-stability/updates/zapret-components-v1.json';
const _versionFile = 'component-versions.json';
const bundledZapretVersions = {
  'Zapret2': 'v1.0.8',
  'Flowseal': '1.10.4',
  'Lua/BAT source': '8dd17fcbcca4',
};
const _luaNames = {
  'zapret-antidpi.lua',
  'zapret-auto.lua',
  'zapret-discord-light.lua',
  'zapret-extsplit.lua',
  'zapret-firstbyte.lua',
  'zapret-ipfrag.lua',
  'zapret-lib.lua',
  'zapret-obfs.lua',
  'zapret-pcap.lua',
  'zapret-sites-light.lua',
  'zapret-syndata.lua',
  'zapret-tests.lua',
  'zapret-tspu-max.lua',
  'zapret-yt4k.lua',
};
const _blobNames = {
  'ACTIVE_DISCORD_UDP.bin',
  'ACTIVE_GAME_UDP.bin',
  'quic_initial_4pda_to.bin',
  'quic_initial_5ka_ru.bin',
  'quic_initial_lemana_pro.bin',
  'quic_initial_rutube_ru.bin',
  'quic_initial_steam_chat_com.bin',
  'quic_initial_steamcommunity_com.bin',
  'quic_initial_steamstatic_com.bin',
  'quic_initial_tencent_com.bin',
  'quic_initial_www_google_com.bin',
  'stun.bin',
  'stun2.bin',
  'tls_clienthello_4pda_to.bin',
  'tls_clienthello_5ka_ru.bin',
  'tls_clienthello_awswaf_com.bin',
  'tls_clienthello_max_ru.bin',
  'tls_clienthello_retext_ai.bin',
  'tls_clienthello_sochi_park.bin',
  'tls_clienthello_steam_chat_com.bin',
  'tls_clienthello_steamstatic_com.bin',
  'tls_clienthello_teamspeak_com.bin',
  'tls_clienthello_www_google_com.bin',
  'tls_clienthello_www_sferum_ru.bin',
};
const _zapret2Files = {
  'winws2.exe', 'WinDivert.dll', 'WinDivert64.sys', 'cygwin1.dll',
};
final _tag = RegExp(r'^v?\d+\.\d+\.\d+$');
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final _gitShaPattern = RegExp(r'^[a-f0-9]{40}$');

Directory get zapretComponentRoot =>
    Directory(p.join(p.dirname(Platform.resolvedExecutable), 'zapret'));

Map<String, String> installedZapretVersions() {
  final versions = Map<String, String>.of(bundledZapretVersions);
  if (!Platform.isWindows) return versions;
  try {
    final file = File(p.join(zapretComponentRoot.path, _versionFile));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
      return versions;
    }
    final json = jsonDecode(file.readAsStringSync());
    if (json is Map) {
      for (final key in versions.keys.toList()) {
        final value = json[key];
        if (value is String && value.length <= 64) versions[key] = value;
      }
    }
  } catch (_) {
    // A damaged version record must not prevent the settings view opening.
  }
  return versions;
}

String gitBlobSha(List<int> data) =>
    sha1.convert([...utf8.encode('blob '+data.length.toString()+'\u0000'), ...data]).toString();

/// No archive entry is extracted by path. Only the exact known runtime file
/// names can be staged, and every download is checked against the catalog.
class ZapretComponentUpdater {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 45),
  ));

  Future<Uint8List> _get(String url, int maxBytes, void Function(String) progress) async {
    var uri = Uri.parse(url);
    final token = CancelToken();
    final deadline = Timer(const Duration(minutes: 3), () => token.cancel('timeout'));
    try {
      for (var i = 0; i < 6; i++) {
        if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443 ||
            !const {'github.com', 'raw.githubusercontent.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}.contains(uri.host)) {
          throw StateError('Недоверенный адрес загрузки');
        }
        final response = await _dio.getUri<ResponseBody>(uri,
          cancelToken: token,
          options: Options(responseType: ResponseType.stream, followRedirects: false,
            validateStatus: (_) => true));
        final body = response.data!;
        if (response.statusCode == 200) {
          final data = BytesBuilder(copy: false);
          await for (final chunk in body.stream) {
            if (data.length + chunk.length > maxBytes) {
              throw StateError('Превышен лимит размера компонента');
            }
            data.add(chunk);
          }
          return data.takeBytes();
        }
        await body.stream.listen(null).cancel();
        final location = response.headers.value('location');
        if ((response.statusCode ?? 0) < 300 || (response.statusCode ?? 0) >= 400 || location == null) {
          throw StateError('Ошибка загрузки HTTP '+response.statusCode.toString());
        }
        uri = uri.resolve(location);
      }
      throw StateError('Слишком много перенаправлений');
    } finally {
      deadline.cancel();
    }
  }

  Future<ZapretComponentTransaction> prepare(
    ZapretComponent component, void Function(String) progress,
  ) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final root = zapretComponentRoot;
    if (FileSystemEntity.typeSync(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw StateError('Каталог Zapret не найден');
    }
    // Use the current user's permissions, never a privileged arbitrary-file IPC.
    final stage = root.createTempSync('.component-update-');
    final transaction = ZapretComponentTransaction(root, stage);
    try {
      progress('Получение каталога совместимых компонентов');
      final raw = await _get(_catalogUrl, 128 * 1024, progress);
      final catalog = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      if (catalog['schema'] != 1) throw StateError('Несовместимый каталог обновления');
      final versions = installedZapretVersions();
      if (component == ZapretComponent.zapret2 || component == ZapretComponent.all) {
        final entry = catalog['zapret2'] as Map;
        final tag = entry['version'] as String;
        if (!_tag.hasMatch(tag) || !tag.startsWith('v')) throw StateError('Некорректная версия Zapret2');
        progress('Загрузка Zapret2 '+tag);
        await _archive(transaction, 'https://github.com/bol-van/zapret2/releases/download/'+tag+'/zapret2-'+tag+'.zip',
          entry['sha256'] as String, _zapret2Files, true, progress);
        versions['Zapret2'] = tag;
      }
      if (component == ZapretComponent.flowseal || component == ZapretComponent.all) {
        final entry = catalog['flowseal'] as Map;
        final tag = entry['version'] as String;
        if (!_tag.hasMatch(tag) || tag.startsWith('v')) throw StateError('Некорректная версия Flowseal');
        progress('Загрузка Flowseal '+tag);
        // The build uses Zapret2's shared WinDivert and Cygwin runtime. Do
        // not silently overwrite those with a different Flowseal copy.
        await _archive(transaction, 'https://github.com/Flowseal/zapret-discord-youtube/releases/download/'+tag+'/zapret-discord-youtube-'+tag+'.zip',
          entry['sha256'] as String, const {'winws.exe'}, false, progress);
        versions['Flowseal'] = tag;
      }
      if (component == ZapretComponent.strategies || component == ZapretComponent.all) {
        final entry = catalog['strategies'] as Map;
        final revision = entry['version'] as String;
        final adapted = entry['adaptedCommit'] as String;
        if (!_gitShaPattern.hasMatch(revision) || !_gitShaPattern.hasMatch(adapted)) {
          throw StateError('Некорректная ревизия стратегий');
        }
        final seen = <String>{};
        for (final item in entry['files'] as List) {
          final file = item as Map;
          final name = file['name'] as String;
          final hash = file['sha'] as String;
          final size = file['size'] as int;
          final isLua = _luaNames.contains(name);
          if ((!isLua && !_blobNames.contains(name)) || !seen.add(name) ||
              !_gitShaPattern.hasMatch(hash) || size <= 0 || size > 8 * 1024 * 1024) {
            throw StateError('Некорректная запись стратегии: '+name);
          }
          progress('Стратегии: '+name);
          final url = isLua
            ? 'https://raw.githubusercontent.com/geliopat/FlClashZ/'+adapted+'/services/helper/strategies/'+name
            : 'https://raw.githubusercontent.com/geliopat/zapret2-gui/'+revision+'/bin/'+name;
          final data = await _get(url, size, progress);
          if (data.length != size || gitBlobSha(data) != hash) {
            throw StateError('Контрольная сумма стратегии не совпала: '+name);
          }
          transaction.stageFile(name, data);
          if (isLua) transaction.stageFile('strategies/'+name, data);
        }
        if (seen.length != _luaNames.length + _blobNames.length) {
          throw StateError('Неполный комплект стратегий');
        }
        versions['Lua/BAT source'] = revision.substring(0, 12);
      }
      transaction.stageFile(_versionFile, utf8.encode(jsonEncode(versions)));
      return transaction;
    } catch (_) {
      transaction.dispose();
      rethrow;
    } finally {
      _dio.close(force: true);
    }
  }

  Future<void> _archive(ZapretComponentTransaction transaction, String url,
      String hash, Set<String> names, bool zapret2, void Function(String) progress) async {
    if (!_sha256Pattern.hasMatch(hash)) throw StateError('Нет SHA256 архива');
    final data = await _get(url, 64 * 1024 * 1024, progress);
    if (sha256.convert(data).toString() != hash) throw StateError('SHA256 архива не совпала');
    final archive = ZipDecoder().decodeBytes(data);
    final found = <String>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final parts = file.name.replaceAll('\\', '/').split('/');
      final name = parts.last;
      if (!names.contains(name)) continue;
      if (zapret2 && (parts.length < 2 || parts[parts.length - 2] != 'windows-x86_64')) continue;
      if (!found.add(name) || file.size <= 0 || file.size > 32 * 1024 * 1024) {
        throw StateError('Недопустимый файл в архиве: '+name);
      }
      transaction.stageFile(name, file.content);
    }
    if (found.length != names.length) throw StateError('Архив не содержит всех необходимых файлов');
  }
}

/// Staging and backup are siblings of the live files, on the same volume.
/// Replacements never touch list files, user strategies or Mihomo.
class ZapretComponentTransaction {
  final Directory root;
  final Directory staging;
  final Map<String, File> _files = {};
  final Map<String, File?> _originals = {};
  Directory? backup;

  ZapretComponentTransaction(this.root, this.staging);

  void stageFile(String relative, List<int> data) {
    if (_files.containsKey(relative)) throw StateError('Повтор файла: '+relative);
    final file = File(p.join(staging.path, 'new', relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data, flush: true);
    _files[relative] = file;
  }

  void apply() {
    if (backup != null) throw StateError('Обновление уже начато');
    final folder = root.createTempSync('.component-backup-');
    backup = folder;
    for (final entry in _files.entries) {
      final target = File(p.join(root.path, entry.key));
      if (FileSystemEntity.typeSync(target.parent.path, followLinks: false) != FileSystemEntityType.directory) {
        throw StateError('Некорректный каталог: '+target.parent.path);
      }
      final kind = FileSystemEntity.typeSync(target.path, followLinks: false);
      if (kind != FileSystemEntityType.file && kind != FileSystemEntityType.notFound) {
        throw StateError('Некорректный тип файла: '+target.path);
      }
      File? original;
      if (kind == FileSystemEntityType.file) {
        final saved = File(p.join(folder.path, entry.key));
        saved.parent.createSync(recursive: true);
        original = target.renameSync(saved.path);
      }
      _originals[entry.key] = original;
      entry.value.renameSync(target.path);
    }
  }

  void rollback() {
    final errors = <String>[];
    for (final entry in _originals.entries.toList().reversed) {
      try {
        final target = File(p.join(root.path, entry.key));
        if (target.existsSync()) target.deleteSync();
        entry.value?.renameSync(target.path);
        _originals.remove(entry.key);
      } catch (error) {
        errors.add(entry.key+': '+error.toString());
      }
    }
    if (errors.isNotEmpty) throw StateError('Откат не завершён: '+errors.join('; '));
  }

  void dispose() {
    try { staging.deleteSync(recursive: true); } catch (_) {}
  }
}
