part of '../action.dart';

@Riverpod(keepAlive: true)
class CommonAction extends _$CommonAction {
  CoreController get _core => ref.read(coreHandlerProvider);
  bool _isUpdatingTraffic = false;
  bool _trayOperationInProgress = false;

  @override
  void build() {}

  void toggleRunning() {
    final running = !ref.read(isStartProvider);
    unawaited(
      globalState.safeRun(
        () => ref
            .read(setupActionProvider.notifier)
            .setRunning(
              running,
              initialize: running && !ref.read(initProvider),
            ),
      ),
    );
  }

  /// The Windows tray is an explicit request for both components.
  /// It does not change the persistent linked-start preference.
  Future<void> toggleTrayRunning() async {
    if (_trayOperationInProgress) return;
    _trayOperationInProgress = true;
    try {
      final zapret = ref.read(zapretControllerProvider);
      final running = ref.read(isStartProvider) || zapret.running || zapret.busy;
      await globalState.safeRun(
        () => ref.read(setupActionProvider.notifier).setTrayRunning(!running),
      );
    } finally {
      _trayOperationInProgress = false;
    }
  }

  /// Use exactly the dashboard's coordinated restart, not app relaunch.
  Future<void> restartFromTray() async {
    if (_trayOperationInProgress || !ref.read(initProvider) ||
        ref.read(coreStatusProvider) == CoreStatus.connecting) return;
    final restartAll = !ref.read(safeModeProvider);
    if (restartAll) {
      final zapret = ref.read(zapretControllerProvider);
      if (zapret.busy || zapret.dashboardRestarting) return;
    }
    _trayOperationInProgress = true;
    try {
      await globalState.safeRun(() async {
        if (restartAll) {
          await ref.read(zapretControllerProvider.notifier)
              .restartFromDashboard(restartAll: true);
        } else {
          await ref.read(coreActionProvider.notifier).restartCore();
        }
      });
    } finally {
      _trayOperationInProgress = false;
    }
  }

  void updateSpeedStatistics() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(showTrayTitle: !state.showTrayTitle));
  }

  void updateMonochromeTrayIcon() {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(monochromeTrayIcon: !state.monochromeTrayIcon),
        );
  }

  /// The cycling hotkey, which has nowhere to ask before taking the mode
  /// over from the subscription.
  void updateMode() {
    ref
        .read(managedSettingsActionProvider.notifier)
        .takeOverIfLocked('clash.mode');
    final modes = ref.read(availableModesProvider);
    ref.read(patchClashConfigProvider.notifier).update((state) {
      final index = modes.indexWhere((item) => item == state.mode);
      final nextIndex = index + 1 > modes.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: modes[nextIndex]);
    });
    ref.read(profileHeadersActionProvider.notifier).forgetTakenMode();
  }

  Future<void> updateTraffic() async {
    if (_isUpdatingTraffic) {
      return;
    }
    _isUpdatingTraffic = true;
    try {
      final onlyStatisticsProxy = ref.read(
        appSettingProvider.select((state) => state.onlyStatisticsProxy),
      );
      final [traffic, totalTraffic] = await Future.wait([
        _readTraffic(() => _core.getTraffic(onlyStatisticsProxy)),
        _readTraffic(() => _core.getTotalTraffic(onlyStatisticsProxy)),
      ]);
      if (traffic != null) {
        ref.read(trafficsProvider.notifier).addTraffic(traffic);
      }
      if (totalTraffic != null) {
        ref.read(totalTrafficProvider.notifier).value = totalTraffic;
      }
    } finally {
      _isUpdatingTraffic = false;
    }
  }

  Future<Traffic?> _readTraffic(Future<Traffic> Function() request) async {
    try {
      return await request();
    } catch (error) {
      commonPrint.log(
        'updateTraffic error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }

  /// The provider's update manifest for this channel, when its header names
  /// one; it then stands in for GitHub as the update source.
  Future<Map<String, dynamic>?> checkForUpdate() async {
    final headers = ref.read(currentProfileProvider)?.headers;
    final manifestUrl = globalState.isPre
        ? headers?.preUpdateManifestUrl
        : headers?.updateManifestUrl;
    // Windows fork releases require our signed manifest. Do not fall back
    // to an unsigned GitHub release when the signing key is not configured.
    if (manifestUrl == null && !Platform.isWindows) {
      return request.checkForUpdate();
    }
    try {
      String? source = manifestUrl;
      if (source == null && globalState.isPre) {
        final release = await request.latestPrerelease();
        final tag = release?['tag_name'];
        if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+-pre\.\d+$').hasMatch(tag)) {
          return null;
        }
        source = 'https://github.com/$repository/releases/download/$tag/manifest.json';
      }
      return await fetchManifestUpdate(
        request.dio,
        Uri.parse(source ?? 'https://github.com/$repository/releases/latest/download/manifest.json'),
        currentVersion: globalState.packageInfo.displayVersion,
        pre: globalState.isPre,
      );
    } catch (error) {
      commonPrint.log(
        'update manifest failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Directory> _updateCacheRoot() async =>
      Directory(join((await appPath.cacheDir.future).path, 'update'));

  /// Clears the downloads of updates this app already runs, once it starts
  /// after installing one.
  Future<void> removeInstalledUpdates() async => removeStaleUpdates(
    await _updateCacheRoot(),
    currentVersion: globalState.packageInfo.displayVersion,
  );

  Future<bool> autoCheckUpdate() async {
    if (!ref.read(appSettingProvider).autoCheckUpdate) return false;
    final Map<String, dynamic>? res;
    try {
      res = await checkForUpdate();
    } catch (error) {
      commonPrint.log(
        'checkForUpdate failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return false;
    }
    if (res == null ||
        res['_required'] != true &&
            res['tag_name'] == ref.read(appSettingProvider).hiddenUpdate) {
      return false;
    }
    await checkUpdateResultHandle(data: res);
    return true;
  }

  TextSpan _releaseSpan(BuildContext context, String? body) {
    final version = parseReleaseChangelog(body);
    return TextSpan(
      children: version == null
          ? [
              TextSpan(text: '\n', style: AppTextStyle.subheadline.of(context)),
              for (final submit in parseReleaseBody(body))
                TextSpan(
                  text: '- $submit \n',
                  style: AppTextStyle.subheadline.of(context),
                ),
            ]
          : _changelogSpans(context, version),
    );
  }

  List<TextSpan> _changelogSpans(
    BuildContext context,
    ChangelogVersion version,
  ) {
    return [
      for (final group in version.visibleGroups) ...[
        TextSpan(
          text:
              '\n${changelogGroupTitle(currentAppLocalizations, group.type)}\n',
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .copyWith(
                color: group.type == ChangelogType.breaking
                    ? context.colorScheme.error
                    : context.colorScheme.primary,
              ),
        ),
        for (final entry in group.entries)
          TextSpan(
            text: '• ${entry.text}\n',
            style: AppTextStyle.subheadline.of(context),
          ),
      ],
    ];
  }

  Future<UpdatePlatform> _updatePlatform() async {
    try {
      return await resolveUpdatePlatform(
        exitApp: () => ref.read(systemActionProvider.notifier).handleExit(),
      );
    } catch (error) {
      commonPrint.log(
        'Update platform unresolved: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return const ManualUpdatePlatform();
    }
  }

  UpdateErrorKind? _updateInstallBlocker() {
    if (ref.read(safeModeProvider)) {
      return UpdateErrorKind.safeMode;
    }
    if (ref.read(setupActionProvider.notifier).isChangingRun) {
      return UpdateErrorKind.busy;
    }
    return null;
  }

  Future<void> checkUpdateResultHandle({
    Map<String, dynamic>? data,
    bool isUser = false,
  }) async {
    if (data != null) {
      final context = globalState.navigatorKey.currentContext!;
      final notes = _releaseSpan(context, data['body'] as String?);
      final platform = await _updatePlatform();
      final required = data['_required'] == true;
      final downloader = UpdateDownloader(root: _updateCacheRoot);
      await dialogs.showCommonDialog<void>(
        // A required update is not put off by a tap beside it.
        dismissible: !required,
        child: UpdateDialog(
          version: data['tag_name'] as String,
          notes: notes,
          onOpenReleasePage: () =>
              unawaited(launchUrl(releasePageOf(data, repository: repository))),
          onHide: isUser || required
              ? null
              : () => ref
                    .read(appSettingProvider.notifier)
                    .update(
                      (state) => state.copyWith(
                        hiddenUpdate: data['tag_name'] as String,
                      ),
                    ),
          createController: () {
            final controller = UpdateController(
              release: data,
              platform: platform,
              downloader: downloader,
              repository: repository,
              pre: globalState.isPre,
              manifest: data['_isManifest'] == true,
              installBlocker: _updateInstallBlocker,
            );
            app?.onPackageInstallStatus = controller.onInstallStatus;
            return controller;
          },
        ),
      );
    } else if (isUser) {
      unawaited(
        dialogs.showAlert(
          title: currentAppLocalizations.checkUpdate,
          message: TextSpan(text: currentAppLocalizations.checkUpdateError),
        ),
      );
    }
  }
}
