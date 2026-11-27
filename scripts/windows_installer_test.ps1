param([string]$Installer = 'dist/FlClashZ-windows-amd64-setup.exe')
$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$root = Join-Path $env:RUNNER_TEMP ("flclashz-install-" + [guid]::NewGuid())
$target = Join-Path $root 'FlClashZ'
$foreign = Join-Path $root 'FlClashX'
$oldKey = 'HKCU:\Software\Classes\flclashx'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$oldUninstall = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\D915C0D1-2F5B-4676-97D5-6D55F3EF45A4_is1'
$ownKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\A1E719DB-1597-4C0E-AC89-05BBED14D43D_is1'
$service = 'FlClashXHelperService'
$created = @()
$uninstaller = $null
$liveApp = $null
$ownCore = $null
$foreignCore = $null
$driverLock = $null
function Assert([bool]$condition, [string]$message) {
  if (!$condition) { throw $message }
}
function CheckForeign {
  Assert ((Get-Content -LiteralPath (Join-Path $foreign 'FlClashX.exe') -Raw) -eq 'foreign') 'Foreign executable changed'
  Assert ((Get-Item -LiteralPath "$oldKey\shell\open\command").GetValue('') -eq ('"' + (Join-Path $foreign 'FlClashX.exe') + '" "%1"')) 'Foreign protocol changed'
  Assert ((Get-ItemPropertyValue -LiteralPath $runKey -Name FlClashX) -eq (Join-Path $foreign 'FlClashX.exe')) 'Foreign autostart changed'
  Assert ((Get-ItemPropertyValue -LiteralPath $oldUninstall -Name DisplayName) -eq 'FlClashX') 'Foreign uninstall entry changed'
  Assert ($null -ne (Get-Service -Name $service -ErrorAction SilentlyContinue)) 'Foreign service deleted'
}
try {
  Assert (!(Test-Path $oldKey)) 'X protocol already exists'
  Assert (!(Test-Path $oldUninstall)) 'X uninstall entry already exists'
  Assert ($null -eq (Get-Service -Name $service -ErrorAction SilentlyContinue)) 'X service already exists'
  New-Item -ItemType Directory -Path $foreign -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $foreign 'FlClashX.exe'), 'foreign')
  New-Item -Path "$oldKey\shell\open\command" -Force | Out-Null
  $created += 'protocol'
  Set-Item -LiteralPath "$oldKey\shell\open\command" -Value ('"' + (Join-Path $foreign 'FlClashX.exe') + '" "%1"')
  New-Item -Path $runKey -Force | Out-Null
  Assert ($null -eq (Get-ItemProperty -LiteralPath $runKey -Name FlClashX -ErrorAction SilentlyContinue)) 'X autostart already exists'
  New-ItemProperty -LiteralPath $runKey -Name FlClashX -Value (Join-Path $foreign 'FlClashX.exe') | Out-Null
  $created += 'run'
  New-Item -Path $oldUninstall -Force | Out-Null
  $created += 'uninstall'
  New-ItemProperty -LiteralPath $oldUninstall -Name DisplayName -Value 'FlClashX' | Out-Null
  New-ItemProperty -LiteralPath $oldUninstall -Name InstallLocation -Value $foreign | Out-Null
  New-Service -Name $service -BinaryPathName ('"' + (Join-Path $foreign 'FlClashX.exe') + '"') -StartupType Manual | Out-Null
  $created += 'service'

  $log = Join-Path $root 'install.log'
  $process = Start-Process -FilePath $Installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=""$target""","/LOG=""$log""") -Wait -PassThru
  if ($process.ExitCode -ne 0) { Get-Content $log -ErrorAction SilentlyContinue; throw "Installer exit code: $($process.ExitCode)" }
  $uninstaller = Join-Path $target 'unins000.exe'
  Assert (Test-Path -LiteralPath $uninstaller) 'Uninstaller missing'
  Assert (Test-Path $ownKey) 'FlClashZ uninstall entry missing'
  foreach ($scheme in @('flclashz','clashz')) {
    $command = (Get-Item -LiteralPath "HKLM:\Software\Classes\$scheme\shell\open\command").GetValue('')
    Assert ($command -eq ('"' + (Join-Path $target 'FlClashZ.exe') + '" "%1"')) "Wrong handler: $scheme"
  }
  CheckForeign
  $liveApp = & "$PSScriptRoot/windows_smoke_test.ps1" -Bundle $target -RequireExistingConsent -KeepRunning
  Assert ($null -ne $liveApp -and !$liveApp.HasExited) 'App must be running before upgrade'
  $ownProbeDir = Join-Path $target 'upgrade-probe'
  New-Item -ItemType Directory -Path $ownProbeDir -Force | Out-Null
  Copy-Item "$env:SystemRoot\System32\ping.exe" (Join-Path $ownProbeDir 'FlClashCore.exe')
  Copy-Item "$env:SystemRoot\System32\ping.exe" (Join-Path $foreign 'FlClashCore.exe')
  $ownCore = Start-Process (Join-Path $ownProbeDir 'FlClashCore.exe') -ArgumentList '-t','127.0.0.1' -WindowStyle Hidden -PassThru
  $foreignCore = Start-Process (Join-Path $foreign 'FlClashCore.exe') -ArgumentList '-t','127.0.0.1' -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 1
  Assert (!$ownCore.HasExited -and !$foreignCore.HasExited) 'Process probes must be running'
  # Reproduce the in-use identical driver case: reads are allowed, delete
  # and writes are denied. The upgrade must leave the exact file untouched.
  $driverPath = Join-Path $target 'zapret\WinDivert64.sys'
  $driverHash = (Get-FileHash -LiteralPath $driverPath -Algorithm SHA256).Hash
  $driverLock = [IO.File]::Open($driverPath, [IO.FileMode]::Open,
    [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $upgradeLog = Join-Path $root 'upgrade.log'
  $process = Start-Process -FilePath $Installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=""$target""","/LOG=""$upgradeLog""") -Wait -PassThru
  if ($process.ExitCode -ne 0) { Get-Content $upgradeLog -ErrorAction SilentlyContinue; throw "Upgrade exit code: $($process.ExitCode)" }
  $driverLock.Dispose(); $driverLock = $null
  Assert ((Get-FileHash -LiteralPath $driverPath -Algorithm SHA256).Hash -eq $driverHash) 'Identical driver changed'
  Assert ((Get-Content -LiteralPath $upgradeLog -Raw).Contains('WinDivert64.sys matches bundled SHA-256')) 'Driver preservation was not exercised'
  $liveApp.Refresh(); $ownCore.Refresh(); $foreignCore.Refresh()
  Assert ($liveApp.HasExited) 'Running application survived upgrade'
  Assert ($ownCore.HasExited) 'Owned orphan Core survived upgrade'
  Assert (!$foreignCore.HasExited) 'Foreign Core was terminated by upgrade'
  CheckForeign
  & "$PSScriptRoot/windows_smoke_test.ps1" -Bundle $target -RequireExistingConsent
  Remove-Item -LiteralPath $ownProbeDir -Recurse -Force
  $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
  Assert ($process.ExitCode -eq 0) "Uninstaller exit code: $($process.ExitCode)"
  $uninstaller = $null
  Assert (!(Test-Path $ownKey)) 'FlClashZ uninstall key survived'
  Assert (!(Test-Path (Join-Path $target 'FlClashZ.exe'))) 'FlClashZ executable survived'
  Assert (!(Test-Path 'HKLM:\Software\Classes\flclashz')) 'FlClashZ handler survived'
  Assert (!(Test-Path 'HKLM:\Software\Classes\clashz')) 'ClashZ handler survived'
  CheckForeign
  Write-Host 'Installer and uninstaller passed; FlClashX sentinels preserved.'
} finally {
  if ($driverLock) { $driverLock.Dispose() }
  foreach ($probe in @($liveApp, $ownCore, $foreignCore)) {
    if ($probe) {
      $probe.Refresh()
      if (!$probe.HasExited) { Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue }
      $probe.Dispose()
    }
  }
  if ($uninstaller -and (Test-Path -LiteralPath $uninstaller)) {
    Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait
  }
  if ('service' -in $created) { & sc.exe delete $service | Out-Null }
  if ('protocol' -in $created) { Remove-Item -LiteralPath $oldKey -Recurse -Force -ErrorAction SilentlyContinue }
  if ('run' -in $created) { Remove-ItemProperty -LiteralPath $runKey -Name FlClashX -ErrorAction SilentlyContinue }
  if ('uninstall' -in $created) { Remove-Item -LiteralPath $oldUninstall -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
