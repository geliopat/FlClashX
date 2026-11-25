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
