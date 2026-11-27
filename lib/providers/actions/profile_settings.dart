part of '../action.dart';

typedef ProfileSettingsSource = ({
  int? id,
  DateTime? updatedAt,
  ProfileType? type,
  ExtendType? extendType,
});

ProfileSettingsSource profileSettingsSourceOf(Profile? profile) => (
  id: profile?.id,
  updatedAt: profile?.lastUpdateDate,
  type: profile?.type,
  extendType: profile?.extendType,
);

/// The current subscription's or file's config keys become the app's
/// settings on every update and switch (see [syncProfileSettings]); a custom
/// profile has no file and a scripted one may rewrite the keys, so both skip.
@Riverpod(keepAlive: true)
class ProfileSettingsAction extends _$ProfileSettingsAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  int _generation = 0;

  // Release requests survive a superseding profile read or transient failure.
  final _released = <String>{};

  /// Set when the Core could not be asked; its next connection asks again.
  bool _unread = false;

  @override
  void build() {
    ref.listen(
      currentProfileProvider.select(profileSettingsSourceOf),
      (_, next) => scheduleMicrotask(() => unawaited(apply(next))),
    );
    ref.listen(coreStatusProvider, (prev, next) {
      if (_unread &&
          next == CoreStatus.connected &&
          prev != CoreStatus.connected) {
        unawaited(
          apply(profileSettingsSourceOf(ref.read(currentProfileProvider))),
        );
      }
    });
    scheduleMicrotask(
      () => unawaited(
        apply(profileSettingsSourceOf(ref.read(currentProfileProvider))),
      ),
    );
  }

  Future<void> apply(ProfileSettingsSource source, {Set<String> released = const {}}) async {
    _released.addAll(released.where(isClashOwnershipKey));
    final id = source.id;
    final generation = ++_generation;
    _unread = false;
    if (id == null ||
        source.type == ProfileType.custom ||
        source.extendType == ExtendType.script) {
      ref.read(managedClashKeysProvider.notifier).set(const {});
      ref.read(globalOverrideProvider.notifier).value = false;
      return;
    }
    final ProfileBase base;
    try {
      base = (await _core.getProfileBase(id)).base;
    } catch (error) {
      commonPrint.log(
        'profile $id settings not read: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      if (ref.mounted && generation == _generation) {
        _unread = true;
      }
      return;
    }
    if (!ref.mounted || generation != _generation) {
      return;
    }
    final modes = ref.read(availableModesProvider);
    final named = base.present.toSet().intersection(managedClashKeys);
    final settings = ref.read(appSettingProvider);
    final previous = previousYamlSources(settings.panelSetSettings);
    final released = Set<String>.of(_released);
    final owned = {
      ...settings.ownedSettings,
      if (!hasYamlSourceVersion(settings.panelSetSettings))
        ...legacyLocalClashKeys(ref.read(patchClashConfigProvider),
          ref.read(networkSettingProvider).authentication, named).difference(released),
    };
    final kept = keptClashKeys(named: named, previous: previous, owned: owned, released: released);
    final resetMissing = {
      for (final key in released)
        if (!owned.contains(key) && !named.contains(key.substring(6))) key,
    };
    ref.read(appSettingProvider.notifier).update((state) => state.copyWith(
      ownedSettings: owned,
      panelSetSettings: withYamlSources(state.panelSetSettings, named),
    ));
    ref
        .read(managedClashKeysProvider.notifier)
        .set(managedClashKeysOf(base.present));
    ref.read(globalOverrideProvider.notifier).value = base.globalOverride;
    ref
        .read(patchClashConfigProvider.notifier)
        .update(
          (state) => keepOwnedSettings(
            state,
            keepOwnedSettings(defaultClashConfig,
              syncProfileSettings(state, base.config, base.present, modes: modes),
              resetMissing),
            kept,
          ),
        );
    if (!kept.contains(clashSettingKey('authentication'))) {
      ref
          .read(networkSettingProvider.notifier)
          .update(
            (state) => state.copyWith(
              authentication: authenticationFrom(base.config['authentication']),
            ),
          );
    }
    _released.removeAll(released);
  }
}
