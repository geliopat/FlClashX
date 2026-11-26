import 'dart:io';

import 'package:fl_clash/common/disclaimer_consent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File marker;
  late int prompts;

  WindowsDisclaimerConsent newStore() =>
      WindowsDisclaimerConsent(markerPath: () async => marker.path);

  Future<bool> accept({bool agree = true, bool legacy = false, bool env = false}) {
    return newStore().ensure(
      legacyAccepted: legacy,
      environmentAccepted: env,
      request: () async {
        prompts++;
        return agree;
      },
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('disclaimer-test-');
    marker = File(p.join(root.path, 'clashz', 'disclaimer.accepted'));
    prompts = 0;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('consent is written before startup and survives a new store', () async {
    expect(await accept(), isTrue);
    expect(await marker.readAsString(), '1\n');
    expect(await accept(), isTrue);
    expect(prompts, 1);
  });

  test('refusal persists nothing', () async {
    expect(await accept(agree: false), isFalse);
    expect(await marker.exists(), isFalse);
    expect(await accept(), isTrue);
    expect(prompts, 2);
  });

  test('existing settings consent migrates without another dialog', () async {
    expect(await accept(legacy: true), isTrue);
    expect(await marker.exists(), isTrue);
    expect(prompts, 0);
  });

  test('explicit unattended acceptance is persisted', () async {
    expect(await accept(env: true), isTrue);
    expect(await accept(), isTrue);
    expect(prompts, 0);
  });

  test('invalid marker requires acceptance again', () async {
    await marker.parent.create(recursive: true);
    await marker.writeAsString('invalid');
    expect(await accept(agree: false), isFalse);
    expect(await marker.readAsString(), 'invalid');
    expect(await accept(), isTrue);
    expect(await marker.readAsString(), '1\n');
    expect(prompts, 2);
  });

  test('deleting the marker and settings requires new acceptance', () async {
    expect(await accept(), isTrue);
    await marker.delete();
    expect(await accept(), isTrue);
    expect(prompts, 2);
  });
}
