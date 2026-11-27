import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/file.dart';

/// Independent recovery copy for cases where the whole preferences store is
/// unreadable. The legacy store remains authoritative when it is valid.
class SettingsRecovery {
  SettingsRecovery(this.file, this.validate);

  final File file;
  final void Function(Map<String, Object?>) validate;

  Map<String, Object?> decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) throw const FormatException('Settings map required');
    validate(decoded);
    return decoded;
  }

  Future<Map<String, Object?>?> read() async {
    if (!await file.exists()) return null;
    return decode(await file.readAsString());
  }

  Future<void> save(String raw) async {
    decode(raw);
    await file.writeAsStringAtomically(raw);
  }

  Future<void> clear() => file.safeDelete();
}
