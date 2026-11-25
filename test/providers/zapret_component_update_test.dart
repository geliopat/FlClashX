import 'dart:io';

import 'package:fl_clash/providers/zapret_component_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Git blob hash includes the Git header', () {
    expect(gitBlobSha([]), 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391');
  });

  test('component update stages, backs up and rolls back only owned files', () {
    final root = Directory.systemTemp.createTempSync('zapret-component-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final engine = File(p.join(root.path, 'winws.exe'))..writeAsStringSync('old');
    final user = File(p.join(root.path, 'list-general-user.txt'))..writeAsStringSync('user');
    final tx = ZapretComponentTransaction(root, root.createTempSync('stage-'));
    addTearDown(tx.dispose);
    tx.stageFile('winws.exe', [1, 2, 3]);
    expect(() => tx.stageFile('../outside.exe', [1]), throwsArgumentError);
    expect(() => tx.stageFile('list-general-user.txt', [1]), throwsArgumentError);
    tx.apply();
    expect(engine.readAsBytesSync(), [1, 2, 3]);
    expect(File(p.join(tx.backup!.path, 'winws.exe')).readAsStringSync(), 'old');
    expect(user.readAsStringSync(), 'user');
    tx.rollback();
    expect(engine.readAsStringSync(), 'old');
    expect(user.readAsStringSync(), 'user');
  });

  test('partial replacement can be rolled back after an invalid target', () {
    final root = Directory.systemTemp.createTempSync('zapret-component-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    final engine = File(p.join(root.path, 'winws.exe'))..writeAsStringSync('old');
    Directory(p.join(root.path, 'winws2.exe')).createSync();
    final tx = ZapretComponentTransaction(root, root.createTempSync('stage-'));
    addTearDown(tx.dispose);
    tx.stageFile('winws.exe', [1]);
    tx.stageFile('winws2.exe', [2]);
    expect(tx.apply, throwsStateError);
    tx.rollback();
    expect(engine.readAsStringSync(), 'old');
    expect(Directory(p.join(root.path, 'winws2.exe')).existsSync(), isTrue);
  });
}
