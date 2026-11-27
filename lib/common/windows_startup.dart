import 'dart:io';

import 'package:path/path.dart' as p;

/// The script is constant: paths and channel names are passed as data, not
/// interpolated into executable PowerShell. Never request elevation.
class WindowsStartupTask {
  WindowsStartupTask({required this.name, required this.executable});
  final String name;
  final String executable;

  static const script = r'''
$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name = $env:FLCLASHZ_STARTUP_NAME + '-' + $sid
$marker = 'FlClashZ owned user logon task v1'
$task = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
if ($null -ne $task -and $task.Description -ne $marker) { throw 'Task ownership mismatch' }
switch ($env:FLCLASHZ_STARTUP_OPERATION) {
  'query' {
    if ($null -ne $task -and $task.State -ne 'Disabled') { 'enabled' } else { 'disabled' }
  }
  'disable' {
    if ($null -ne $task) { Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false }
    'ok'
  }
  'enable' {
    $exe = $env:FLCLASHZ_STARTUP_EXE
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Executable missing' }
    $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe))
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
    $trigger.Delay = 'PT10S'
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $marker -Force | Out-Null
    'ok'
  }
  default { throw 'Unknown startup operation' }
}
''';

  Future<String> _run(String operation) async {
    final root = Platform.environment['SystemRoot'];
    if (root == null) throw StateError('Windows SystemRoot missing');
    final shell = p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    final result = await Process.run(shell, ['-NoProfile', '-NonInteractive', '-Command', script],
      environment: {
        'FLCLASHZ_STARTUP_NAME': name,
        'FLCLASHZ_STARTUP_EXE': executable,
        'FLCLASHZ_STARTUP_OPERATION': operation,
      }).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) throw StateError('Scheduled startup operation failed: $operation');
    return result.stdout.toString().trim();
  }

  Future<bool> isEnabled() async => await _run('query') == 'enabled';
  Future<bool> enable() async => await _run('enable') == 'ok';
  Future<bool> disable() async => await _run('disable') == 'ok';
}
