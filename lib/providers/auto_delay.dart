import 'dart:async';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef AutoDelayIntervals = ({int active, int others});
typedef AutoDelayBatch = ({List<Proxy> proxies, String? testUrl});

/// DIRECT is a measurable route. REJECT, REJECT-DROP and PASS do not
/// provide an outbound route with a useful latency.
bool isAutoDelayProbeable(String name) =>
    name == 'DIRECT' || !isBuiltinOutbound(name);

/// Include every member and the group itself, including root-level groups
/// which are not members of another group. The same resolver as manual
/// testing deduplicates the effective (outbound, URL) targets.
List<AutoDelayBatch> autoDelayBatches(List<Group> groups) {
  return [
    for (final group in groups)
      (
        proxies: [
          Proxy(name: group.name, type: group.type.name),
          for (final proxy in group.all)
            if (isAutoDelayProbeable(proxy.name)) proxy,
        ],
        testUrl: group.testUrl,
      ),
    // DIRECT may also be displayed without being a member of a group.
    if (groups.isNotEmpty)
      (proxies: const [Proxy(name: 'DIRECT', type: 'Direct')], testUrl: null),
  ];
}

bool autoDelayDue({
  required DateTime now,
  required DateTime? last,
  required int seconds,
}) => seconds > 0 &&
    (last == null || now.difference(last) >= Duration(seconds: seconds));

final autoDelayProvider = NotifierProvider<AutoDelayController, AutoDelayIntervals>(AutoDelayController.new);
class AutoDelayController extends Notifier<AutoDelayIntervals> {
  static const values = [0, 5, 10, 15, 30, 60, 120];
  @override
  AutoDelayIntervals build() {
    scheduleMicrotask(() async {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getInt('delay.activeInterval');
      final others = prefs.getInt('delay.otherInterval');
      if (ref.mounted) {
        state = (active: values.contains(active) ? active! : 15,
            others: values.contains(others) ? others! : 60);
      }
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
