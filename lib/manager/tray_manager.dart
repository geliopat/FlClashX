import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/tray.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/providers/zapret.dart';
import 'package:fl_clash/providers/auto_delay.dart';
import 'package:fl_clash/providers/smart_hosts.dart';
import 'package:fl_clash/providers/zapret_diagnostics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray/tray.dart';

class TrayManager extends ConsumerStatefulWidget {
  final Widget child;

  const TrayManager({super.key, required this.child});

  @override
  ConsumerState<TrayManager> createState() => _TrayManagerState();
}

class _TrayManagerState extends ConsumerState<TrayManager> {
  StreamSubscription<TrayEvent>? _subscription;
  bool _isUpdating = false;
  bool _hasPendingUpdate = false;

  @override
  void initState() {
    super.initState();
    _subscription = Tray.instance.events.listen(_handleTrayEvent);
    ref.listenManual(trayStateProvider, (prev, next) {
      if (prev != next) {
        _requestUpdate();
      }
    });
    ref.listenManual(loadedLocaleProvider, (prev, next) {
      if (prev != null && prev != next) {
        _requestUpdate();
      }
    });
    if (system.isWindows) {
      ref.read(proxiesActionProvider.notifier);
      ref.read(autoDelayProvider);
      ref.listenManual(zapretControllerProvider.select((state) => (
        state.running, state.busy, state.available, state.selectedStrategyId,
        state.mode, state.startWithMihomo, state.strategies,
      )), (_, _) => _requestUpdate());
      ref.listenManual(zapretDiagnosticsProvider, (_, _) {});
      ref.listenManual(smartHostsProvider.select((state) => state.revision), (_, _) {
        if (ref.read(initProvider)) {
          unawaited(ref.read(setupActionProvider.notifier).applyProfile(force: true, silence: true).then((ok) async {
            if (ok && mounted) await ref.read(coreActionProvider.notifier).clearDnsCacheOnNetworkChange();
          }).catchError((Object error) {
            commonPrint.log('Smart Hosts apply failed: $error', logLevel: LogLevel.warning);
          }));
        }
      });
    }
    if (system.isMacOS) {
      ref.listenManual(trayDelaysProvider, (prev, next) {
        if (!const DeepCollectionEquality().equals(prev, next)) {
          _requestUpdate();
        }
      });
      ref.listenManual(trayTitleStateProvider, (prev, next) {
        if (prev != next) {
          _reportFailure(
            appTray?.updateTitle(
              showTrayTitle: next.showTrayTitle,
              traffic: next.traffic,
            ),
          );
        }
      });
    }
  }

  /// A delay test changes the menu per proxy, so updates in flight coalesce.
  void _requestUpdate() {
    if (_isUpdating) {
      _hasPendingUpdate = true;
      return;
    }
    _isUpdating = true;
    _reportFailure(_drainUpdates());
  }

  Future<void> _drainUpdates() async {
    try {
      do {
        _hasPendingUpdate = false;
        await ref.read(systemActionProvider.notifier).updateTray();
      } while (_hasPendingUpdate && mounted);
    } finally {
      _isUpdating = false;
      if (_hasPendingUpdate && mounted) {
        _requestUpdate();
      }
    }
  }

  void _reportFailure(Future<void>? operation) {
    if (operation == null) {
      return;
    }
    unawaited(
      operation.onError<Object>((error, stackTrace) {
        commonPrint.log(
          'Tray operation failed: ${compactError(error)}',
          logLevel: LogLevel.error,
        );
      }),
    );
  }

  void _handleTrayEvent(TrayEvent event) {
    switch (event) {
      case TrayIconActivated():
        _reportFailure(window?.show());
      case TrayMenuRequested():
        _reportFailure(Tray.instance.openMenu());
      case TrayMenuItemSelected():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
