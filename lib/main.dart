import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'application.dart';
import 'bootstrap.dart';
import 'common/app_data.dart';
import 'common/common.dart';
import 'common/preferences_store.dart';
import 'common/window.dart';
import 'providers/providers.dart';

const _flowsealElevatedLaunchArgument = '--flowseal-elevated';
const _flowsealStartLaunchArgument = '--flowseal-start=';
const _flowsealInstallRootPreference = 'flowseal.installRoot';

class _FlowsealLaunchIntent {
  final String strategy;
  final String gameFilterMode;
  final String gameFilterTcp;
  final String gameFilterUdp;

  const _FlowsealLaunchIntent({
    required this.strategy,
    required this.gameFilterMode,
    required this.gameFilterTcp,
    required this.gameFilterUdp,
  });
}

bool _validFlowsealPortRange(String value) {
  if (value.isEmpty || value.length > 64) return false;
  for (final character in value.codeUnits) {
    final digit = character >= 48 && character <= 57;
    if (!digit && character != 44 && character != 45) return false;
  }
  for (final part in value.split(',')) {
    final bounds = part.split('-');
    if (bounds.isEmpty ||
        bounds.length > 2 ||
        bounds.any((bound) => bound.isEmpty)) {
      return false;
    }
    final start = int.tryParse(bounds.first);
    final end = int.tryParse(bounds.length == 2 ? bounds.last : bounds.first);
    if (start == null ||
        end == null ||
        start < 1 ||
        end > 65535 ||
        start > end) {
      return false;
    }
  }
  return true;
}

_FlowsealLaunchIntent? _readFlowsealLaunchIntent(List<String> args) {
  String? encoded;
  for (final argument in args) {
    if (argument.startsWith(_flowsealStartLaunchArgument)) {
      if (encoded != null) return null;
      encoded = argument.substring(_flowsealStartLaunchArgument.length);
    }
  }
  if (encoded == null || encoded.isEmpty || encoded.length > 4096) return null;
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
    );
    if (decoded is! Map<String, dynamic>) return null;
    final strategy = decoded['strategy'];
    final mode = decoded['gameFilterMode'];
    final tcp = decoded['gameFilterTcp'];
    final udp = decoded['gameFilterUdp'];
    if (strategy is! String ||
        strategy.trim().isEmpty ||
        strategy.length > 64 ||
        mode is! String ||
        !const {'none', 'all', 'tcp', 'udp'}.contains(mode) ||
        tcp is! String ||
        (const {'all', 'tcp'}.contains(mode) &&
            !_validFlowsealPortRange(tcp)) ||
        udp is! String ||
        (const {'all', 'udp'}.contains(mode) &&
            !_validFlowsealPortRange(udp))) {
      return null;
    }
    return _FlowsealLaunchIntent(
      strategy: strategy,
      gameFilterMode: mode,
      gameFilterTcp: tcp,
      gameFilterUdp: udp,
    );
  } catch (_) {
    return null;
  }
}

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      if (args.contains(restartCoreArgument)) {
        exit((await runRestartCoreCli()).code);
      }
      fileLogger.enable();
      if (Platform.isWindows || Platform.isLinux) {
        SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
          appPath.sharedPreferencesPath,
        );
      }
      if (Platform.isLinux) {
        linkManager.seedInitialLink(args);
      }
      FlutterError.onError = (details) {
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      try {
        await RustLib.init();
        final version = await system.init();
        final container = await bootstrap.init(
          version,
          waitForDataLock:
              Platform.isWindows &&
              args.contains(_flowsealElevatedLaunchArgument),
        );

        final flowsealIntent =
            Platform.isWindows && args.contains(_flowsealElevatedLaunchArgument)
            ? _readFlowsealLaunchIntent(args)
            : null;
        final hasFlowsealStartRequest = args.any(
          (argument) => argument.startsWith(_flowsealStartLaunchArgument),
        );
        String? flowsealStartError;
        int? flowsealStartedPid;
        if (args.contains(_flowsealElevatedLaunchArgument) &&
            hasFlowsealStartRequest &&
            flowsealIntent == null) {
          flowsealStartError =
              'The elevated Flowseal start request was missing or invalid.';
          commonPrint.log(flowsealStartError, logLevel: LogLevel.warning);
        } else if (flowsealIntent != null) {
          try {
            final preferences = await SharedPreferences.getInstance();
            final savedRoot = preferences.getString(
              _flowsealInstallRootPreference,
            );
            final root = savedRoot == null || savedRoot.trim().isEmpty
                ? p.join(await appPath.homeDirPath, 'Flowseal')
                : savedRoot;
            final status = await flowsealStart(
              root: root,
              strategy: flowsealIntent.strategy,
              gameFilterMode: flowsealIntent.gameFilterMode,
              gameFilterTcp: flowsealIntent.gameFilterTcp,
              gameFilterUdp: flowsealIntent.gameFilterUdp,
            );
            flowsealStartedPid = status.pid;
            commonPrint.log(
              'Flowseal UAC handoff started strategy '
              '${flowsealIntent.strategy} (PID ${status.pid ?? 'unknown'})',
            );
          } catch (error) {
            flowsealStartError = error.toString();
            commonPrint.log(
              'Flowseal UAC handoff could not start the strategy: $error',
              logLevel: LogLevel.error,
            );
          }
        }

        await FlClashHttpOverrides.trustCoreRoots();
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        runApp(
          UncontrolledProviderScope(
            container: container,
            child: const Application(),
          ),
        );
        if (flowsealIntent != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final error = flowsealStartError;
            if (error != null) {
              dialogs.showNotifier(
                'Не удалось запустить Flowseal: $error',
                level: MessageLevel.error,
              );
            } else {
              dialogs.showNotifier(
                'Flowseal запущен · PID ${flowsealStartedPid ?? '-'}',
                level: MessageLevel.info,
              );
            }
          });
        }
        if (Platform.isWindows &&
            args.contains(_flowsealElevatedLaunchArgument) &&
            !hasFlowsealStartRequest) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            dialogs.showNotifier(
              'FlClashX запущен с правами администратора.',
              level: MessageLevel.success,
            );
          });
        }
        if (system.isDesktop) {
          unawaited(
            coreCliServer.start(
              restartCore: () => _restartCoreByCommand(container),
            ),
          );
        }
      } catch (e, s) {
        runApp(
          InitErrorApp(
            error: e,
            stack: s,
            onClearData: clearAppData,
            onExit: _exitAfterInitFailure,
          ),
        );
        unawaited(window?.showInitFailure(onExit: _exitAfterInitFailure));
      }
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

/// A restart asked from the command line shows in the app as one asked there.
Future<bool> _restartCoreByCommand(ProviderContainer container) async {
  final appLocalizations = currentAppLocalizations;
  try {
    final restarted = await container
        .read(coreActionProvider.notifier)
        .restartCore();
    dialogs.showNotifier(
      restarted
          ? appLocalizations.coreRestartedByCommand
          : appLocalizations.coreRestartByCommandFailed,
      level: restarted ? MessageLevel.info : MessageLevel.error,
    );
    return restarted;
  } catch (error) {
    dialogs.showNotifier(
      '${appLocalizations.coreRestartByCommandFailed}: $error',
      level: MessageLevel.error,
    );
    rethrow;
  }
}

Future<void> _exitAfterInitFailure() async {
  await system.exit();
  window?.forceExit();
}
