import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/core/desktop/core_manifest.dart';
import 'package:path/path.dart' as p;

Future<List<String>> checkWindowsComponents() async {
  if (!Platform.isWindows) return const [];
  final failures = <String>[];
  Future<void> verify(String root, String name, Object? hash) async {
    final parts = name.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..' ||
        part.contains(RegExp(r'[:\\]'))) ||
        hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      failures.add('invalid manifest entry');
      return;
    }
    try {
      final file = File(p.joinAll([root, ...parts]));
      if (!await file.exists() || (await sha256.bind(file.openRead()).first).toString() != hash) {
        failures.add(name);
      }
    } catch (_) {
      failures.add(name);
    }
  }
  final root = appPath.executableDirPath;
  await verify(root, 'FlClashCore.exe', await CoreManifest.readCoreSha256());
  if (!await File(appPath.helperPath).exists()) failures.add('Helper');
  final zapret = p.join(root, 'zapret');
  try {
    final decoded = jsonDecode(await File(p.join(zapret, 'integrity.json')).readAsString());
    if (decoded is! Map<String, dynamic>) throw const FormatException('manifest');
    for (final name in ['winws.exe', 'winws2.exe', 'WinDivert.dll', 'WinDivert64.sys', 'cygwin1.dll', 'zapret-lib.lua']) {
      if (!decoded.containsKey(name)) failures.add(name);
    }
    for (final entry in decoded.entries) {
      await verify(zapret, entry.key, entry.value);
    }
  } catch (_) {
    failures.add('zapret/integrity.json');
  }
  return failures;
}
