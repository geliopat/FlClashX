part of '../action.dart';

@Riverpod(keepAlive: true)
class ManagedSettingsAction extends _$ManagedSettingsAction {
  @override
  void build() {}

  void takeOver(String key) {
    if (ref.read(appSettingProvider).ownedSettings.contains(key)) return;
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            ownedSettings: {...state.ownedSettings, key},
            headerBackup: headerBackupWithout(state.headerBackup, key),
          ),
        );
  }

  /// Asks before the user takes [key] over from the subscription; true once
  /// it is theirs to change.
  Future<bool> confirmTakeOver(String key) async {
    if (!ref.read(settingLockedProvider(key))) {
      if (isClashOwnershipKey(key)) takeOver(key);
      return true;
    }
    final agreed = await dialogs.showMessage(
      title: currentAppLocalizations.managedByProvider,
      message: TextSpan(text: currentAppLocalizations.managedByProviderTip),
      confirmText: currentAppLocalizations.takeOver,
    );
    if (agreed != true || !ref.mounted) {
      return false;
    }
    if (zapretPageKeys.contains(key)) {
      await ref.read(zapretControllerProvider.notifier).preserveManagedValue(key);
      if (!ref.mounted) return false;
    }
    takeOver(key);
    return true;
  }

  /// For a change from the tray or a hotkey, which has nowhere to ask.
  void takeOverIfLocked(String key) {
    if (isClashOwnershipKey(key) || ref.read(settingLockedProvider(key))) {
      takeOver(key);
    }
  }

  /// Gives [key] back without applying the subscription's value, for a
  /// caller that has already put the setting back itself.
  void disown(String key) {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            ownedSettings: {...state.ownedSettings}..remove(key),
          ),
        );
  }

  void release(String key) {
    disown(key);
    if (!zapretPageKeys.contains(key)) _reapply(released: {key});
  }

  void releaseAll() {
    final owned = ref.read(appSettingProvider).ownedSettings;
    for (final profile in ref.read(profilesProvider)) {
      final interval = profile.headers.updateInterval;
      if (interval != null &&
          owned.contains(profileUpdateIntervalSetting(profile.id))) {
        ref.read(profilesProvider.notifier).put(
          profile.copyWith(autoUpdateDuration: interval),
        );
      }
    }
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(ownedSettings: const {}));
    _reapply(released: owned);
  }

  void _reapply({Set<String> released = const {}}) {
    final profile = ref.read(currentProfileProvider);
    ref
        .read(profileHeadersActionProvider.notifier)
        .apply(profileHeaderSettingsOf(profile));
    unawaited(
      ref
          .read(profileSettingsActionProvider.notifier)
          .apply(profileSettingsSourceOf(profile), released: released),
    );
  }
}
