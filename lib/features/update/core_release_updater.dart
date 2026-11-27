import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/features/update/asset.dart';
import 'package:fl_clash/features/update/core_release_manifest.dart';
import 'package:fl_clash/features/update/download.dart';

final class PreparedCoreRelease {
  final CoreReleaseManifest manifest;
  final List<int> manifestBytes;
  final File binary;
  final bool downloaded;

  const PreparedCoreRelease._(this.manifest, this.manifestBytes, this.binary, this.downloaded);

  /// Only delete our private download directory, never a local import.
  Future<void> dispose() async {
    if (downloaded && await binary.parent.exists()) {
      await binary.parent.delete(recursive: true);
    }
  }
}

/// Retrieval never changes the active core. The signed package is staged via
/// the owner-authenticated Helper, then activation goes through CoreAction.
final class CoreReleaseUpdater {
  final UpdateDownloader downloader;
  final HelperClient helper;

  const CoreReleaseUpdater({required this.downloader, required this.helper});

  Set<String> _hosts(Uri uri) => {...updateHosts, uri.host.toLowerCase()};

  Future<PreparedCoreRelease> download({
    String url = defaultCoreManifestUrl,
    CancelToken? cancelToken,
    UpdateProgress? onProgress,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !isAllowedUpdateUri(uri, hosts: _hosts(uri))) {
      throw const UpdateException(UpdateErrorKind.untrustedHost, 'Core manifest URL');
    }
    final bytes = await downloader.fetchBytes(
      uri, limit: coreManifestMaxBytes, hosts: _hosts(uri),
      cancelToken: cancelToken,
    );
    final manifest = await CoreReleaseManifest.verify(bytes);
    final file = await downloader.download(
      UpdateAsset(
        name: 'FlClashCore.exe', url: manifest.uri, checksum: manifest.hash,
        size: manifest.size, allowedHosts: _hosts(manifest.uri),
      ),
      cancelToken: cancelToken, onProgress: onProgress,
    );
    final prepared = PreparedCoreRelease._(manifest, bytes, file, true);
    try {
      await manifest.verifyBinary(file);
      return prepared;
    } catch (_) {
      await prepared.dispose();
      rethrow;
    }
  }

  Future<PreparedCoreRelease> importLocal({
    required File manifestFile,
    required File binary,
  }) async {
    if (await manifestFile.length() > coreManifestMaxBytes) {
      throw const FormatException('Oversized core manifest');
    }
    final bytes = <int>[];
    await for (final chunk in manifestFile.openRead()) {
      if (bytes.length + chunk.length > coreManifestMaxBytes) {
        throw const FormatException('Oversized core manifest');
      }
      bytes.addAll(chunk);
    }
    final manifest = await CoreReleaseManifest.verify(bytes);
    await manifest.verifyBinary(binary);
    return PreparedCoreRelease._(manifest, bytes, binary, false);
  }

  Future<CoreReleaseManifest> stage(PreparedCoreRelease package) async {
    await helper.stageCoreRelease(
      manifest: package.manifest, manifestBytes: package.manifestBytes,
      binary: package.binary,
    );
    return package.manifest;
  }
}
