import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/features/update/core_release_manifest.dart';
import 'package:fl_clash/features/update/core_release_updater.dart';
import 'package:fl_clash/features/update/download.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
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

  test('authenticates actual candidate core with the configured test key', () async {
    final directory = Platform.environment['FLCLASHZ_TEST_SIGNED_CORE_DIR'];
    if (directory == null) return;
    final bytes = await File('$directory/core-manifest.json').readAsBytes();
    final verified = await CoreReleaseManifest.verify(bytes);
    expect(verified.version.value, 'v1.19.34-z.3');
    expect(verified.engineRevision, '3e8de1205af9e4fb7cb6a1d56f8bd36b4ada5d67');
    expect(verified.hostRevision, 'e57f5bdcff7c7a9df4df0f22957da4073f2b6249');
    await verified.verifyBinary(File('$directory/FlClashCore.exe'));
    final modified = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    modified['version'] = 'v1.19.34-z.4';
    await expectLater(CoreReleaseManifest.verify(utf8.encode(jsonEncode(modified))), throwsFormatException);
  });

  test('downloads the candidate z3 using the actual client downloader and isolated transport', () async {
    final directory = Platform.environment['FLCLASHZ_TEST_SIGNED_CORE_DIR'];
    if (directory == null) return;
    final expected = await CoreReleaseManifest.verify(
      await File('$directory/core-manifest.json').readAsBytes(),
    );
    await expected.verifyBinary(File('$directory/FlClashCore.exe'));
    final root = await Directory.systemTemp.createTemp('core_release_download_');
    try {
      // Serve the exact pre-publication executable through the real downloader
      // using an isolated transport fixture. Never use a production signing key.
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
        final name = options.uri.pathSegments.last;
        if (options.uri.scheme != 'https' || options.uri.host != 'github.com' ||
            (name != 'core-manifest.json' && name != 'FlClashCore.exe')) {
          handler.reject(DioException(requestOptions: options, error: 'unexpected fixture URL'));
          return;
        }
        final file = File('$directory/$name');
        final bytes = await file.readAsBytes();
        handler.resolve(Response<ResponseBody>(
          requestOptions: options, statusCode: 200,
          data: ResponseBody.fromBytes(bytes, 200, headers: {
            Headers.contentLengthHeader: ['${bytes.length}'],
          }),
        ));
      }));
      final updater = CoreReleaseUpdater(
        downloader: UpdateDownloader(root: () async => root, dio: dio),
        helper: HelperClient(),
      );
      final offer = await updater.check(url:
        'https://github.com/geliopat/Clash.Meta/releases/download/flclashz-core-v1.19.34-z.3/core-manifest.json');
      expect(offer.manifest.version.value, 'v1.19.34-z.3');
      expect(offer.manifest.hash, expected.hash);
      expect(offer.manifest.hostRevision, 'e57f5bdcff7c7a9df4df0f22957da4073f2b6249');
      expect(offer.manifest.engineRevision, expected.engineRevision);
      final downloaded = await updater.downloadOffer(offer);
      try {
        await downloaded.manifest.verifyBinary(downloaded.binary);
        expect(await downloaded.binary.length(), expected.size);
      } finally {
        await downloaded.dispose();
      }
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('orders independent revisions numerically', () {
    final a = CoreReleaseVersion.parse('v1.19.34-z.9');
    final b = CoreReleaseVersion.parse('v1.19.34-z.10');
    final c = CoreReleaseVersion.parse('v1.20.0-z.1');
    expect(a.compareTo(b), lessThan(0));
    expect(b.compareTo(c), lessThan(0));
    expect(() => CoreReleaseVersion.parse('v1.19.34-z.0'), throwsFormatException);
  });
}
