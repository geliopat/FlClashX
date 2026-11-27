import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/ui/material_appearance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const materialAppearanceKey = 'theme.materialAppearance.v1';

final materialAppearanceProvider =
    NotifierProvider<MaterialAppearanceController, MaterialAppearance>(
      MaterialAppearanceController.new,
    );

class MaterialAppearanceController extends Notifier<MaterialAppearance> {
  int _revision = 0;
  Future<void> _writes = Future.value();

  @override
  MaterialAppearance build() {
    unawaited(_load());
    return defaultMaterialAppearance;
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(materialAppearanceKey);
      if (raw != null && ref.mounted && revision == _revision) {
        state = decodeMaterialAppearance(Map<String, Object?>.from(jsonDecode(raw) as Map));
      }
    } catch (_) {
      // Preserve old appearance defaults when the optional settings are absent.
    }
  }

  void preview(MaterialAppearance value) {
    _revision++;
    state = value;
  }

  Future<void> save(MaterialAppearance value) {
    preview(value);
    final encoded = jsonEncode(encodeMaterialAppearance(value));
    final operation = _writes.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(materialAppearanceKey, encoded)) {
        throw StateError('Unable to save material appearance');
      }
    });
    _writes = operation;
    return operation;
  }
}
