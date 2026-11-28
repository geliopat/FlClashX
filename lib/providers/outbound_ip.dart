import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core.dart';
import 'network_probe_settings.dart';
import 'route_state.dart';
import 'routed_probe.dart';

part 'generated/outbound_ip.g.dart';

/// Keyed by the outbound a lookup pins: a node name, `DIRECT`, or
/// [routedOutbound] for whatever the rules pick right now.
@Riverpod(keepAlive: true)
class OutboundIpProbe extends _$OutboundIpProbe
    with RoutedProbe<String, IpInfo> {
  @override
  RoutedProbeState<String, IpInfo> build() {
    final initial = buildProbe();
    ref.listen(networkProbeSettingsProvider.select((s) => s.ipKey), (_, _) => probeSettingsChanged());
    return initial;
  }

  @override
  Future<Map<String, ProbeAnswer<IpInfo>>> probe(
    String target,
    RouteState route,
  ) async {
    final proxyName = target == routedOutbound && !route.proxied
        ? directOutbound
        : target;
    final settings = ref.read(networkProbeSettingsProvider);
    final core = ref.read(coreHandlerProvider);
    final selected = settings.selectedIpUrl;
    final timeout = Duration(seconds: settings.ipTimeout);
    final watch = Stopwatch()..start();
    var result = await lookupOutboundIp(core, proxyName,
      urls: selected == null ? null : [selected],
      timeout: selected != null && settings.ipFallback
          ? Duration(milliseconds: timeout.inMilliseconds ~/ 2) : timeout,
    );
    var value = parseOutboundIp(result, customUrl: settings.customIpUrl);
    // Optional fallback uses the same named outbound and remaining budget.
    if (value == null && selected != null && settings.ipFallback) {
      final remaining = timeout - watch.elapsed;
      final alternatives = ipInfoSources.keys.where((url) => url != selected).toList();
      if (remaining > Duration.zero && alternatives.isNotEmpty) {
        result = await lookupOutboundIp(core, proxyName, urls: alternatives, timeout: remaining);
        value = parseOutboundIp(result, customUrl: settings.customIpUrl);
      }
    }
    final hits = result?.hits ?? const <RouteHit>[];
    final exit = result?.chains.firstOrNull;
    return {
      target: ProbeAnswer(
        value: value,
        coreEpoch: result?.coreEpoch,
        routeVersion: result?.routeVersion,
        hits: hits,
      ),
      // A node leaves through the same address whatever it is asked for.
      if (value != null && exit != null && exit != target)
        exit: ProbeAnswer(
          value: value,
          coreEpoch: result?.coreEpoch,
          routeVersion: result?.routeVersion,
          hits: result?.nodeHits ?? const [],
        ),
    };
  }
}
