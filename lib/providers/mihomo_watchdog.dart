import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final mihomoWatchdogProvider = NotifierProvider<MihomoWatchdog, bool>(MihomoWatchdog.new);
class MihomoWatchdog extends Notifier<bool> {
  static const _key = 'mihomo.watchdog';
  @override
  bool build() {
    scheduleMicrotask(() async {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted) state = prefs.getBool(_key) ?? true;
    });
    return true;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
