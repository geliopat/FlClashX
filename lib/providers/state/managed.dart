part of '../state.dart';

/// Null means the current YAML has not been read successfully yet; an empty
/// map means it names none of the typed settings. This is runtime-only.
final yamlSettingReferencesProvider =
    NotifierProvider<YamlSettingReferences, Map<String, Object>?>(YamlSettingReferences.new);

class YamlSettingReferences extends Notifier<Map<String, Object>?> {
  @override
  Map<String, Object>? build() => null;

  void set(Map<String, Object>? values) {
    state = values == null ? null : Map.unmodifiable(values);
  }
}

@Riverpod(keepAlive: true)
class ManagedClashKeys extends _$ManagedClashKeys {
  @override
  Set<String> build() => const {};

  void set(Set<String> keys) {
    if (!const SetEquality<String>().equals(keys, state)) {
      state = keys;
    }
  }
}

/// Every setting the current subscription speaks for.
@riverpod
Set<String> managedSettings(Ref ref) {
  final switches = ref.watch(
    currentProfileProvider.select((profile) => profile?.headers.appSwitches),
  );
  final view = ref.watch(
    currentProfileProvider.select((profile) => profile?.headers.view),
  );
  final hideIp = ref.watch(
    currentProfileProvider.select(
      (profile) => profile?.headers.hideIp ?? false,
    ),
  );
  final noVibration = ref.watch(
    currentProfileProvider.select(
      (profile) => profile?.headers.noVibration ?? false,
    ),
  );
  final widgetsManaged = ref.watch(
    currentProfileProvider.select((profile) =>
        profile?.headers.dashboardWidgets != null &&
        !(profile?.headers.widgetEditingDenied ?? false)),
  );
  return {
    if (widgetsManaged) dashboardWidgetsSetting,
    if (switches != null) ...appSwitchSettings.values,
    if (hideIp) hideIpSetting,
    if (noVibration) vibrationSetting,
    ...managedViewKeysOf(view),
    ...managedZapretKeysOf(ref.watch(currentProfileProvider.select((profile) => profile?.headers.zapret))),
    ...ref.watch(managedClashKeysProvider),
  };
}

@riverpod
bool settingOwned(Ref ref, String key) => ref.watch(
  appSettingProvider.select((state) => state.ownedSettings.contains(key)),
);

@riverpod
bool settingLocked(Ref ref, String key) =>
    ref.watch(managedSettingsProvider.select((keys) => keys.contains(key))) &&
    !ref.watch(settingOwnedProvider(key));

@riverpod
bool settingReleasable(Ref ref, String key) =>
    ref.watch(managedSettingsProvider.select((keys) => keys.contains(key))) &&
    ref.watch(settingOwnedProvider(key));
