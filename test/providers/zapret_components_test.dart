import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/providers/zapret_components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zapret-versions-');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<void> writeManifest(Map<String, dynamic> components) async {
    await File(p.join(dir.path, 'versions.json')).writeAsString(
      jsonEncode({'schema': 1, 'components': components}),
    );
  }

  test('missing manifest does not claim an installed version', () async {
    final versions = await readZapretComponentVersions(dir);
    expect(versions.values, everyElement('неизвестно'));
  });

  test('reads verified version and rejects changed binary', () async {
    final file = File(p.join(dir.path, 'winws.exe'));
    final bytes = utf8.encode('test binary');
    await file.writeAsBytes(bytes);
    final hash = sha256.convert(bytes).toString();
    await writeManifest({
      'Flowseal': {
        'version': '1.10.4',
        'archiveSha256': hash,
        'files': {'winws.exe': hash},
      },
    });
    expect((await readZapretComponentVersions(dir))['Flowseal'], '1.10.4');
    await file.writeAsString('changed');
    expect((await readZapretComponentVersions(dir))['Flowseal'], 'неизвестно');
  });

  test('verifies GUI source and Lua version with imported BAT names', () async {
    final files = <String, String>{};
    for (final name in [
      'zapret-lib.lua', 'zapret-auto.lua', 'zapret-antidpi.lua', 'zapret-obfs.lua',
      'strategies/zapret-lib.lua', 'strategies/zapret-auto.lua',
      'strategies/zapret-antidpi.lua', 'strategies/zapret-obfs.lua',
      'strategies/imported/kinlay0/general (ALT14).bat',
    ]) {
      final bytes = utf8.encode(name);
      final file = File(p.joinAll([dir.path, ...name.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      files[name] = sha256.convert(bytes).toString();
    }
    await writeManifest({
      'Lua/BAT source': {
        'version': '8dd17fcbcca405a50f497a6e2346ca263901d775',
        'luaLibraryVersion': 'v1.0.8',
        'files': files,
      },
    });
    expect((await readZapretComponentVersions(dir))['Lua/BAT source'],
        '8dd17fcbcca4 + Lua v1.0.8');
  });

  test('rejects a manifest with paths outside the component directory', () async {
    final bytes = utf8.encode('test binary');
    final hash = sha256.convert(bytes).toString();
    await File(p.join(dir.path, 'winws.exe')).writeAsBytes(bytes);
    await writeManifest({
      'Flowseal': {
        'version': '1.10.4',
        'archiveSha256': hash,
        'files': {'winws.exe': hash, '../outside.exe': hash},
      },
    });
    expect((await readZapretComponentVersions(dir))['Flowseal'], 'неизвестно');
  });
}
