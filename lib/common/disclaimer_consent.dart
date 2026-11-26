import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

import 'print.dart';

/// One explicit consent for this Windows installation, independent of profiles,
/// app version, stable/pre channels and portable/installed executable paths.
const disclaimerRegistryPath = r'SOFTWARE\sweetyyoba.com\FlClashZ';
const disclaimerRegistryValue = 'DisclaimerAccepted';

class WindowsDisclaimerConsent {
  WindowsDisclaimerConsent({
    required this.readMachine,
    required this.readUser,
    required this.writeUser,
    required this.writeMachine,
  });

  final bool Function() readMachine;
  final bool Function() readUser;
  final bool Function() writeUser;
  final Future<bool> Function({required bool allowElevation}) writeMachine;

  /// Never save acceptance for a declined or dismissed dialog.
  /// HKCU is a durable fallback if the user declines the first UAC prompt.
  Future<bool> ensure({
    required bool legacyAccepted,
    required bool environmentAccepted,
    required Future<bool> Function() request,
  }) async {
    if (readMachine() || readUser()) return true;
    if (!legacyAccepted && !environmentAccepted && !await request()) {
      return false;
    }
    final localSaved = writeUser();
    final machineSaved = await writeMachine(
      allowElevation: !environmentAccepted,
    );
    if (!localSaved && !machineSaved) {
      commonPrint.log('Disclaimer consent could not be persisted');
    }
    return true;
  }
}

bool _readAcceptance({required bool machine}) {
  try {
    final key = (machine ? LOCAL_MACHINE : CURRENT_USER).open(
      disclaimerRegistryPath,
    );
    try {
      return switch (key.getValue(disclaimerRegistryValue)) {
        StringValue(:final value) => value == '1',
        _ => false,
      };
    } finally {
      key.close();
    }
  } catch (_) {
    return false;
  }
}

bool _writeAcceptance({required bool machine}) {
  try {
    final key = (machine ? LOCAL_MACHINE : CURRENT_USER).create(
      disclaimerRegistryPath,
    );
    try {
      key.setValue(disclaimerRegistryValue, RegistryValue.string('1'));
    } finally {
      key.close();
    }
    return _readAcceptance(machine: machine);
  } catch (_) {
    return false;
  }
}

/// The only elevated operation is adding this fixed, non-sensitive value.
/// Unattended starts never open a UAC prompt.
Future<bool> _writeMachine({required bool allowElevation}) async {
  if (_writeAcceptance(machine: true)) return true;
  if (!allowElevation) return false;
  try {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = await Process.run(
      '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        r'''try {
  $p = Start-Process -FilePath "$env:SystemRoot\System32\reg.exe" -ArgumentList 'add "HKLM\SOFTWARE\sweetyyoba.com\FlClashZ" /v DisclaimerAccepted /t REG_SZ /d 1 /f /reg:64' -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
  exit $p.ExitCode
} catch { exit 1 }''',
      ],
    );
    return result.exitCode == 0 && _readAcceptance(machine: true);
  } catch (_) {
    return false;
  }
}

final windowsDisclaimerConsent = WindowsDisclaimerConsent(
  readMachine: () => _readAcceptance(machine: true),
  readUser: () => _readAcceptance(machine: false),
  writeUser: () => _writeAcceptance(machine: false),
  writeMachine: _writeMachine,
);
