import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_profiles.dart';

void main() {
  test('Zapret ownership survives header refresh and can be released', () {
    const profile = Profile(
      id: 1,
      type: ProfileType.url,
      autoUpdateDuration: Duration.zero,
      label: 'Zapret',
      providerHeaders: {
        'flclashz-zapret': 'autostart,autofallback,mode:strictsplit',
      },
    );
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
      ],
    );
    addTearDown(container.dispose);
    final action = container.read(managedSettingsActionProvider.notifier);
    expect(container.read(settingLockedProvider(zapretStartSetting)), isTrue);
    expect(container.read(settingLockedProvider(zapretFallbackSetting)), isTrue);
    expect(container.read(settingLockedProvider(zapretModeSetting)), isTrue);
    expect(container.read(settingLockedProvider(zapretTuneModeSetting)), isFalse);

    action.takeOver(zapretStartSetting);
    expect(container.read(settingLockedProvider(zapretStartSetting)), isFalse);
    expect(container.read(settingReleasableProvider(zapretStartSetting)), isTrue);
    expect(container.read(settingLockedProvider(zapretFallbackSetting)), isTrue);

    container.read(profilesProvider.notifier).put(profile.copyWith(
      providerHeaders: {'flclashz-zapret': 'autostart,tunemode:full'},
    ));
    expect(container.read(settingLockedProvider(zapretStartSetting)), isFalse);
    expect(container.read(settingLockedProvider(zapretModeSetting)), isFalse);
    expect(container.read(settingLockedProvider(zapretTuneModeSetting)), isTrue);

    action.release(zapretStartSetting);
    expect(container.read(settingLockedProvider(zapretStartSetting)), isTrue);
    expect(container.read(settingReleasableProvider(zapretStartSetting)), isFalse);
  });
}
