import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef AutoDelayIntervals = ({int active, int others});
final autoDelayProvider = NotifierProvider<AutoDelayController, AutoDelayIntervals>(AutoDelayController.new);
class AutoDelayController extends Notifier<AutoDelayIntervals> {
  static const values = [0, 5, 10, 15, 30, 60, 120];
  @override
  AutoDelayIntervals build() {
    scheduleMicrotask(() async {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getInt('delay.activeInterval');
      final others = prefs.getInt('delay.otherInterval');
      if (ref.mounted) state = (active: values.contains(active) ? active! : 15,
          others: values.contains(others) ? others! : 60);
    });
    return (active: 15, others: 60);
  }

  Future<void> set({int? active, int? others}) async {
    if (active != null && !values.contains(active) || others != null && !values.contains(others)) return;
    state = (active: active ?? state.active, others: others ?? state.others);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('delay.activeInterval', state.active);
    await prefs.setInt('delay.otherInterval', state.others);
  }
}
