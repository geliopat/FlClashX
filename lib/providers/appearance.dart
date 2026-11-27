import 'dart:async';

import 'package:fl_clash/ui/hover_glow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const glowIntensityPreferenceKey = 'theme.glowIntensity';

final glowIntensityProvider = NotifierProvider<GlowIntensityController, double>(
  GlowIntensityController.new,
);

class GlowIntensityController extends Notifier<double> {
  int _revision = 0;
  Future<void> _writes = Future.value();

  @override
  double build() {
    unawaited(_load());
    return defaultGlowIntensity;
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted && revision == _revision) {
        state = normalizeGlowIntensity(prefs.getDouble(glowIntensityPreferenceKey));
      }
    } catch (_) {
      // Malformed or unavailable settings keep the default without hiding UI.
    }
  }

  void preview(double value) {
    _revision++;
    state = normalizeGlowIntensity(value);
  }

  Future<void> save(double value) {
    preview(value);
    final saved = state;
    final operation = _writes.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setDouble(glowIntensityPreferenceKey, saved)) {
        throw StateError('Unable to save glow intensity');
      }
    });
    _writes = operation;
    return operation;
  }
}
