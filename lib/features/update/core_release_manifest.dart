import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/features/update/manifest_signature.dart';

const defaultCoreManifestUrl =
    'https://github.com/geliopat/Clash.Meta/releases/latest/download/core-manifest.json';
// One release trust root, separate canonical signature domains.
const coreUpdateManifestKeys = updateManifestKeys;

const coreManifestMaxBytes = 16 * 1024;
const coreBinaryMaxBytes = 256 * 1024 * 1024;
const supportedCoreIpcRevision = 1;
// z.1 has the engine patches but predates the adapter capabilities.
const minimumIndependentCoreVersion = 'v1.19.34-z.2';
const _product = 'FlClashZ-core';
const _name = 'FlClashCore.exe';
final _version = RegExp(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-z\.([1-9][0-9]*)$');
final _revision = RegExp(r'^[0-9a-f]{40}$');
final _hash = RegExp(r'^[0-9a-f]{64}$');

bool _matches(RegExp pattern, String value) =>
    pattern.firstMatch(value)?.group(0) == value;

final class CoreReleaseVersion implements Comparable<CoreReleaseVersion> {
  final String value;
  final List<BigInt> _parts;

  CoreReleaseVersion._(this.value, this._parts);

  factory CoreReleaseVersion.parse(String value) {
    if (value.length > 96 || !_matches(_version, value)) {
      throw const FormatException('Invalid independent core version');
    }
    final match = _version.firstMatch(value)!;
    return CoreReleaseVersion._(
      value,
      List.unmodifiable(List.generate(4, (i) => BigInt.parse(match.group(i + 1)!))),
    );
  }

  String get mihomoVersion => value.split('-').first;

  @override
  int compareTo(CoreReleaseVersion other) {
    for (var i = 0; i < _parts.length; i++) {
      final comparison = _parts[i].compareTo(other._parts[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }
}

/// Only created after verifying the signature and compatibility contract.
/// File verification alone is NOT authorization to launch a privileged binary:
/// the lifecycle owner and Helper must independently validate the staged file.
final class CoreReleaseManifest {
  final CoreReleaseVersion version;
  final String engineRevision;
  final String hostRevision;
  final int ipcRevision;
  final int size;
  final String hash;
  final Uri uri;
  final String signature;

  const CoreReleaseManifest._({
    required this.version,
    required this.engineRevision,
    required this.hostRevision,
    required this.ipcRevision,
    required this.size,
    required this.hash,
    required this.uri,
    required this.signature,
  });

  static Future<CoreReleaseManifest> verify(
    List<int> bytes, {
    List<String> keys = coreUpdateManifestKeys,
  }) async {
    if (bytes.isEmpty || bytes.length > coreManifestMaxBytes) {
      throw const FormatException('Invalid core manifest length');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid core manifest object');
    }
    String field(String name) {
      final v = value[name];
      if (v is! String) throw FormatException('Invalid core manifest field: $name');
      return v;
    }

    if (value['schema'] is! int || value['schema'] != 1 ||
        field('product') != _product || field('name') != _name ||
        field('os') != 'windows' || field('arch') != 'amd64' ||
        value['ipcRevision'] is! int ||
        value['ipcRevision'] != supportedCoreIpcRevision) {
      throw const FormatException('Incompatible core manifest identity');
    }
    final version = CoreReleaseVersion.parse(field('version'));
    if (field('mihomoVersion') != version.mihomoVersion) {
      throw const FormatException('Inconsistent Mihomo version');
    }
    final engine = field('engineRevision');
    final host = field('hostRevision');
    final hash = field('sha256');
    final size = value['size'];
    if (!_matches(_revision, engine) || !_matches(_revision, host) ||
        !_matches(_hash, hash) || size is! int || size <= 0 ||
        size > coreBinaryMaxBytes) {
      throw const FormatException('Invalid core manifest provenance or size');
    }
    final uri = Uri.tryParse(field('url'));
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      throw const FormatException('Invalid core asset URL');
    }
    final result = CoreReleaseManifest._(
      version: version,
      engineRevision: engine,
      hostRevision: host,
      ipcRevision: supportedCoreIpcRevision,
      size: size,
      hash: hash,
      uri: uri,
      signature: field('signature'),
    );
    if (!await verifyUpdateManifestSignature(
      result.signingBytes,
      result.signature,
      keys: keys,
    )) {
      throw const FormatException('Invalid core manifest signature');
    }
    return result;
  }

  List<int> get signingBytes => utf8.encode([
    'flclashz-core-manifest-v1',
    '1',
    _product,
    version.value,
    version.mihomoVersion,
    engineRevision,
    hostRevision,
    '$ipcRevision',
    'windows',
    'amd64',
    _name,
    '$size',
    hash,
    '',
  ].join('\n'));

  /// Use only on a private staging file; the privileged verifier repeats this
  /// check before execution. Do not treat the result as a persistent file lease.
  Future<void> verifyBinary(File file) async {
    if (await file.length() != size) {
      throw const FormatException('Core binary size mismatch');
    }
    var read = 0;
    final digest = await sha256.bind(file.openRead().map((chunk) {
      read += chunk.length;
      if (read > size) throw const FormatException('Core binary too large');
      return chunk;
    })).first;
    if (read != size || digest.toString() != hash) {
      throw const FormatException('Core binary hash mismatch');
    }
  }
}
