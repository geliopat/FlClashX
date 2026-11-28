import 'dart:async';

import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/enum/enum.dart';
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
  int _revision = 0;
  Future<void> _writes = Future.value();
  @override
  AutoDelayIntervals build() {
    final revision = _revision;
    scheduleMicrotask(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final active = prefs.getInt('delay.activeInterval');
        final others = prefs.getInt('delay.otherInterval');
        if (ref.mounted && revision == _revision) {
          state = (active: values.contains(active) ? active! : 15,
              others: values.contains(others) ? others! : 60);
        }
      } catch (_) {
        commonPrint.log('Automatic delay settings unavailable', logLevel: LogLevel.warning);
      }
    });
    return (active: 15, others: 60);
  }

  Future<void> set({int? active, int? others}) async {
    if (active != null && !values.contains(active) || others != null && !values.contains(others)) return;
    ++_revision;
    final snapshot = (active: active ?? state.active, others: others ?? state.others);
    state = snapshot;
    final operation = _writes.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final activeSaved = await prefs.setInt('delay.activeInterval', snapshot.active);
      final othersSaved = await prefs.setInt('delay.otherInterval', snapshot.others);
      if (!activeSaved || !othersSaved) {
        throw StateError('Automatic delay settings save failed');
      }
    });
    _writes = operation;
    await operation;
  }
}
