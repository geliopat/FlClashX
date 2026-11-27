import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/features/update/core_release_manifest.dart';
import 'package:fl_clash/features/update/manifest_signature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binary = utf8.encode('test core payload');
  final engine = List.filled(40, 'a').join();
  final host = List.filled(40, 'b').join();
  final hash = sha256.convert(binary).toString();
  late Map<String, Object> manifest;
  late String publicKey;

  setUp(() async {
    manifest = {
      'schema': 1,
      'product': 'FlClashZ-core',
      'version': 'v1.19.34-z.2',
      'mihomoVersion': 'v1.19.34',
      'engineRevision': engine,
      'hostRevision': host,
      'ipcRevision': 1,
      'os': 'windows',
      'arch': 'amd64',
      'name': 'FlClashCore.exe',
      'size': binary.length,
      'sha256': hash,
      'url': 'https://example.com/core.exe',
    };
    // Explicit fixture for the Go signer's canonical LF-delimited format.
    final signed = await signUpdateManifest(
      utf8.encode('flclashz-core-manifest-v1\n1\nFlClashZ-core\nv1.19.34-z.2\nv1.19.34\n$engine\n$host\n1\nwindows\namd64\nFlClashCore.exe\n${binary.length}\n$hash\n'),
      List.generate(32, (i) => i),
    );
    publicKey = signed.publicKey;
    manifest['signature'] = signed.signature;
  });

  Future<CoreReleaseManifest> verify() => CoreReleaseManifest.verify(
    utf8.encode(jsonEncode(manifest)),
    keys: [publicKey],
  );

  test('validates signed identity and exact binary bytes', () async {
    final verified = await verify();
    final directory = await Directory.systemTemp.createTemp('core_release_test_');
    try {
      final file = File('${directory.path}/FlClashCore.exe');
      await file.writeAsBytes(binary);
      await verified.verifyBinary(file);
      await file.writeAsBytes(List.filled(binary.length, 0));
      await expectLater(verified.verifyBinary(file), throwsFormatException);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects changed signed provenance and incompatible IPC', () async {
    manifest['hostRevision'] = List.filled(40, 'c').join();
    await expectLater(verify(), throwsFormatException);
    manifest['hostRevision'] = host;
    manifest['ipcRevision'] = 2;
    await expectLater(verify(), throwsFormatException);
  });

  test('allows HTTPS mirror, not arbitrary insecure transport', () async {
    manifest['url'] = 'https://mirror.example.com/core.exe';
    expect((await verify()).uri.host, 'mirror.example.com');
    manifest['url'] = 'http://mirror.example.com/core.exe';
    await expectLater(verify(), throwsFormatException);
  });

  test('fails closed without a trusted signing key', () async {
    await expectLater(CoreReleaseManifest.verify(
      utf8.encode(jsonEncode(manifest)), keys: [],
    ), throwsFormatException);
  });

  test('authenticates actual published core with the shared release key', () async {
    final directory = Platform.environment['FLCLASHZ_TEST_SIGNED_CORE_DIR'];
    if (directory == null) return;
    final bytes = await File('$directory/core-manifest.json').readAsBytes();
    final verified = await CoreReleaseManifest.verify(bytes);
    expect(verified.version.value, 'v1.19.34-z.1');
    expect(verified.engineRevision, '53d2f4fc1cb56aaeba947a1a557eeafd48050737');
    await verified.verifyBinary(File('$directory/FlClashCore.exe'));
    final modified = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    modified['version'] = 'v1.19.34-z.2';
    await expectLater(CoreReleaseManifest.verify(utf8.encode(jsonEncode(modified))), throwsFormatException);
  });

  test('orders independent revisions numerically', () {
    final a = CoreReleaseVersion.parse('v1.19.34-z.9');
    final b = CoreReleaseVersion.parse('v1.19.34-z.10');
    final c = CoreReleaseVersion.parse('v1.20.0-z.1');
    expect(a.compareTo(b), lessThan(0));
    expect(b.compareTo(c), lessThan(0));
    expect(() => CoreReleaseVersion.parse('v1.19.34-z.0'), throwsFormatException);
  });
}
