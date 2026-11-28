import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/desktop/core_release_selection.dart';
import 'package:fl_clash/features/update/core_release_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
  const fixture = '{"schema":1,"product":"FlClashZ-core","version":"v1.19.34-z.2","mihomoVersion":"v1.19.34","engineRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","hostRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ipcRevision":1,"os":"windows","arch":"amd64","name":"FlClashCore.exe","size":17,"sha256":"4b6add73f177ebfb9c02f0316b70a4bf1bc3c73d9199c1964194e5b4f078244e","url":"https://example.com/core.exe","signature":"uwHIJSmA8VVNi33h6dtCOQSL4lExnP/v9Spe6hOFFCxpE1Gsh+YvMorZVUJTgIeziCqQOPpXh4EIO562bJiaDw=="}';
  late Directory directory;
  late File file;
  late CoreReleaseSelectionStore store;
  late CoreReleaseManifest manifest;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('core_selection_test_');
    file = File('${directory.path}/selection.json');
    store = CoreReleaseSelectionStore(() async => file);
    manifest = await CoreReleaseManifest.verify(utf8.encode(fixture), keys: [key]);
  });

  tearDown(() async => directory.delete(recursive: true));

  test('commits only after restart; explicit restore returns to bundled core', () async {
    expect(await store.activate(manifest, bundledVersion: 'v1.19.34', restart: () async {
      expect((await store.selectedForLaunch())?.hash, manifest.hash);
      final afterCrash = CoreReleaseSelectionStore(() async => file);
      expect(await afterCrash.selectedForLaunch(), isNull);
      expect((await afterCrash.read()).pending, isTrue);
      return true;
    }), isTrue);
    expect((await store.read()).current?.hash, manifest.hash);
    expect((await store.read()).pending, isFalse);
    expect(await store.restorePrevious(restart: () async {
      expect(await store.selectedForLaunch(), isNull);
      return true;
    }), isTrue);
    expect(await store.selectedForLaunch(), isNull);
    expect((await store.read()).previous?.hash, manifest.hash);
  });

  test('automatically reselects previous core after a failed trial', () async {
    final hashes = <String?>[];
    await expectLater(
      store.activate(manifest, bundledVersion: 'v1.19.34', restart: () async {
        hashes.add((await store.selectedForLaunch())?.hash);
        return hashes.length == 2;
      }),
      throwsA(isA<CoreReleaseActivationException>().having((e) => e.restored, 'restored', isTrue)),
    );
    expect(hashes, [manifest.hash, null]);
    expect((await store.read()).pending, isFalse);
    expect(await store.selectedForLaunch(), isNull);
  });

  test('committed slot verification failure recovers bundled core', () async {
    await store.activate(manifest, bundledVersion: 'v1.19.34', restart: () async => true);
    expect(await store.rejectCommitted(manifest.hash), isTrue);
    expect(await store.selectedForLaunch(), isNull);
  });

  test('a trial cannot be silently substituted by a launch failure', () async {
    await expectLater(store.activate(manifest, bundledVersion: 'v1.19.34', restart: () async {
      final selected = await store.selectedForLaunch();
      if (selected == null) return true;
      expect(await store.rejectCommitted(selected.hash), isFalse);
      return false;
    }), throwsA(isA<CoreReleaseActivationException>()));
    expect(await store.selectedForLaunch(), isNull);
  });

  test('crash during durable commit restores previous selection', () async {
    var checks = 0;
    await expectLater(store.activate(
      manifest, bundledVersion: 'v1.19.34', restart: () async => true,
      healthy: () => ++checks != 2,
    ), throwsA(isA<CoreReleaseActivationException>().having((e) => e.restored, 'restored', isTrue)));
    expect(await store.selectedForLaunch(), isNull);
    expect((await store.read()).pending, isFalse);
  });

  test('does not downgrade the bundled core', () async {
    await expectLater(store.activate(manifest, bundledVersion: 'v1.20.0', restart: () async {
      fail('Incompatible downgrade must not restart');
    }), throwsStateError);
    expect(await file.exists(), isFalse);
  });

  test('incompatible z1 selection does not replace compatible bundled core', () async {
    final old = {'hash': List.filled(64, 'a').join(), 'version': 'v1.19.34-z.1'};
    final current = CoreReleaseRef.fromManifest(manifest).toJson();
    final guarded = CoreReleaseSelectionStore(() async => file,
        minimumVersion: CoreReleaseVersion.parse('v1.19.34-z.2'));
    await file.writeAsString(jsonEncode({
      'schema': 1, 'current': old, 'previous': null, 'hasPrevious': true, 'pending': false,
    }));
    expect(await guarded.selectedForLaunch(), isNull);
    // Retain the old signed slot, but never select it as a rollback target.
    await file.writeAsString(jsonEncode({
      'schema': 1, 'current': current, 'previous': old, 'hasPrevious': true, 'pending': false,
    }));
    expect((await guarded.read()).previous, isNull);
    expect(await guarded.restorePrevious(restart: () async {
      expect(await guarded.selectedForLaunch(), isNull);
      return true;
    }), isTrue);
  });

  test('does not accept malformed selected paths', () async {
    await file.writeAsString('{"schema":1,"current":{"hash":"../evil.exe","version":"v1.19.34-z.2"},"hasPrevious":false,"pending":false}');
    expect(await store.selectedForLaunch(), isNull);
  });
}
