import 'package:fl_clash/common/disclaimer_consent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late bool machine;
  late bool user;
  late bool allowMachineWrite;
  late int prompts;
  late int elevationRequests;

  WindowsDisclaimerConsent newStore() => WindowsDisclaimerConsent(
    readMachine: () => machine,
    readUser: () => user,
    writeUser: () => user = true,
    writeMachine: ({required bool allowElevation}) async {
      if (allowElevation) elevationRequests++;
      return machine = allowMachineWrite;
    },
  );

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

  setUp(() {
    machine = false;
    user = false;
    allowMachineWrite = true;
    prompts = 0;
    elevationRequests = 0;
  });

  test('acceptance survives a fresh store and a different Windows user', () async {
    expect(await accept(), isTrue);
    expect(machine, isTrue);
    user = false;
    expect(await accept(), isTrue);
    expect(prompts, 1);
    expect(elevationRequests, 1);
  });

  test('refusal persists nothing', () async {
    expect(await accept(agree: false), isFalse);
    expect(machine, isFalse);
    expect(user, isFalse);
    expect(await accept(), isTrue);
    expect(prompts, 2);
  });

  test('a denied elevation retains the user consent without prompting again', () async {
    allowMachineWrite = false;
    expect(await accept(), isTrue);
    expect(user, isTrue);
    expect(machine, isFalse);
    expect(await accept(), isTrue);
    expect(prompts, 1);
    expect(elevationRequests, 1);
  });

  test('existing accepted settings migrate without another disclaimer', () async {
    expect(await accept(legacy: true), isTrue);
    expect(machine, isTrue);
    expect(prompts, 0);
  });

  test('unattended consent never requests elevation', () async {
    allowMachineWrite = false;
    expect(await accept(env: true), isTrue);
    expect(prompts, 0);
    expect(elevationRequests, 0);
    expect(user, isTrue);
  });
}
