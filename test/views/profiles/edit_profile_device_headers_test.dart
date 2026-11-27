import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';

import '../../helpers/app_paths.dart';
import '../../helpers/test_profiles.dart';
import '../../widgets/edit_profile_focus_test.dart';

class _RecordingProfilesAction extends ProfilesAction {
  final updated = <Profile>[];
  final put = <Profile>[];

  @override
  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    updated.add(profile);
  }

  @override
  void putProfile(Profile profile) {
    put.add(profile);
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('edit_profile_device');
    await useAppPaths(tempDir);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Finder row() =>
      find.widgetWithText(FormRow, currentAppLocalizations.sendDeviceHeaders);

  bool switchedOn(WidgetTester tester) => tester
      .widget<Switch>(find.descendant(of: row(), matching: find.byType(Switch)))
      .value;

  testWidgets('a subscription shows the switch the way the profile has it', (
    tester,
  ) async {
    final profile = Profile.normal(
      label: 'test',
      url: 'https://example.com/sub',
      sendDeviceHeaders: false,
    );
    await pumpEditProfile(
      tester,
      profile: profile,
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
      ],
    );

    expect(row(), findsOneWidget);
    expect(switchedOn(tester), isFalse);
  });

  testWidgets('a local file has no device id to send', (tester) async {
    final profile = Profile.normal(label: 'local');
    await pumpEditProfile(
      tester,
      profile: profile,
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
      ],
    );

    expect(row(), findsNothing);
  });

  testWidgets('provider interval can be handed back using its context menu', (
    tester,
  ) async {
    final profile = Profile.normal(
      label: 'test',
      url: 'https://example.com/sub',
    ).copyWith(
      autoUpdateDuration: const Duration(hours: 12),
      providerHeaders: {'profile-update-interval': '12'},
    );
    await pumpEditProfile(tester, profile: profile, overrides: [
      profilesProvider.overrideWith(() => TestProfiles([profile])),
    ]);
    final interval = find.widgetWithText(
      FormRow, currentAppLocalizations.autoUpdateInterval,
    );
    await tester.tap(interval);
    await tester.pumpAndSettle();
    await tester.tap(find.text(currentAppLocalizations.takeOver));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: interval, matching: find.byType(TextFormField),
    );
    await tester.enterText(field, '60');
    await tester.tap(interval, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(currentAppLocalizations.returnToProvider));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(field).controller!.text, '720');
  });

  testWidgets('turning it off saves the profile and fetches it again', (
    tester,
  ) async {
    final profile = Profile.normal(
      label: 'test',
      url: 'https://example.com/sub',
    );
    final action = _RecordingProfilesAction();
    await pumpEditProfile(
      tester,
      profile: profile,
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        profilesActionProvider.overrideWith(() => action),
      ],
    );
    expect(switchedOn(tester), isTrue);

    await tester.tap(row());
    await tester.pump();
    expect(switchedOn(tester), isFalse);

    await tester.tap(find.byTooltip(currentAppLocalizations.save));
    await tester.pump(commonDuration);
    await tester.pumpAndSettle();

    expect(action.put, isEmpty);
    expect(action.updated, hasLength(1));
    expect(action.updated.single.sendDeviceHeaders, isFalse);
  });
}
