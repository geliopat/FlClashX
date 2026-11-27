param(
  [Parameter(Mandatory=$true)][ValidateSet('Stop','Release','CheckDriver','UnloadDriver')][string]$Phase,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][string]$AppExe,
  [Parameter(Mandatory=$true)][string]$ServiceName,
  [Parameter(Mandatory=$true)][string]$Endpoint,
  [Parameter(Mandatory=$true)][string]$StateFile
)
$ErrorActionPreference = 'Stop'
$prefix = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
$comparison = [StringComparison]::OrdinalIgnoreCase
$names = @($AppExe, ($ServiceName + '.exe'), 'FlClashCore.exe', 'winws.exe', 'winws2.exe')
function InInstall([string]$Path) {
  return ($Path -and $Path.StartsWith($prefix, $comparison))
}
function OwnedProcesses {
  foreach ($p in Get-CimInstance Win32_Process) {
    if ($names -contains $p.Name -and (InInstall $p.ExecutablePath)) { $p }
  }
}
function OwnedService {
  $s = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
  if (!$s) { return $null }
  $image = $s.PathName
  if ($image -match '^"([^"]+)"') { $image = $Matches[1] }
  elseif ($image -match '^(.*?\.exe)(?:\s|$)') { $image = $Matches[1] }
  $image = [Environment]::ExpandEnvironmentVariables($image)
  if (!(InInstall $image)) { return $null }
  return $s
}
function InvokeSc([string[]]$Arguments) {
  & "$env:SystemRoot\System32\sc.exe" @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "sc.exe failed: $Arguments ($LASTEXITCODE)" }
}
function WaitUntil([scriptblock]$Condition, [int]$Seconds) {
  $until = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $until)
  return (& $Condition)
}
function StopOwned([object]$Candidate) {
  $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($Candidate.ProcessId)"
  if ($current -and $current.CreationDate -eq $Candidate.CreationDate -and
      $names -contains $current.Name -and (InInstall $current.ExecutablePath)) {
    try { Stop-Process -Id $current.ProcessId -Force -ErrorAction Stop }
    catch {
      if (Get-Process -Id $current.ProcessId -ErrorAction SilentlyContinue) { throw }
    }
  }
}
# SCM can report an NT path, a quoted DOS path, or a SystemRoot-relative path.
function DriverImage([string]$Path) {
  if (!$Path) { return $null }
  $image = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
  if ($image.StartsWith('\??\') -or $image.StartsWith('\\?\')) {
    $image = $image.Substring(4)
  }
  if ($image.StartsWith('\SystemRoot\', $comparison)) {
    $image = Join-Path $env:SystemRoot $image.Substring(12)
  }
  try {
    if (![IO.Path]::IsPathRooted($image)) { return $null }
    return [IO.Path]::GetFullPath($image)
  } catch { return $null }
}
function OwnedWinDivertDrivers {
  $expected = Join-Path $prefix 'zapret\WinDivert64.sys'
  foreach ($driver in Get-CimInstance Win32_SystemDriver) {
    if ($driver.Name -match '^WinDivert[0-9.]*$' -and
        [string]::Equals((DriverImage $driver.PathName), $expected, $comparison)) {
      $driver
    }
  }
}
function UnloadOwnedWinDivert {
  $drivers = @(OwnedWinDivertDrivers)
  if (!$drivers.Count) { return }
  # WinDivert uses global services; do not interfere with known foreign engines.
  $foreignEngines = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('winws.exe','winws2.exe') -and !(InInstall $_.ExecutablePath)
  })
  if ($foreignEngines.Count) { throw 'Other Zapret engines are running; shared WinDivert will not be stopped' }
  foreach ($driver in $drivers) {
    $current = @(OwnedWinDivertDrivers | Where-Object Name -eq $driver.Name)
    if (!$current.Count -or $current[0].State -eq 'Stopped') { continue }
    Write-Host "Stopping owned WinDivert driver: $($driver.Name)"
    if ($current[0].State -ne 'Stop Pending') {
      & "$env:SystemRoot\System32\sc.exe" stop $driver.Name | Out-Host
    }
    if (!(WaitUntil {
      $active = @(OwnedWinDivertDrivers | Where-Object {
        $_.Name -eq $driver.Name -and $_.State -ne 'Stopped'
      })
      $active.Count -eq 0
    } 15)) { throw "Owned WinDivert driver did not unload: $($driver.Name)" }
  }
}
function AskAppToExit {
  if (!(Test-Path -LiteralPath $Endpoint)) { return $false }
  $client = $null
  try {
    $endpointData = Get-Content -LiteralPath $Endpoint -Raw | ConvertFrom-Json
    if ($endpointData.port -lt 1 -or $endpointData.port -gt 65535 -or !$endpointData.token) { return $false }
    $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $endpointData.port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1) { return $false }
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($listeners[0].OwningProcess)"
    if (!$owner -or $owner.Name -ne $AppExe -or !(InInstall $owner.ExecutablePath)) { return $false }
    $client = New-Object Net.Sockets.TcpClient
    $connect = $client.ConnectAsync('127.0.0.1', [int]$endpointData.port)
    if (!$connect.Wait(3000)) { return $false }
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $stream = $client.GetStream()
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 1024, $true)
    $reader = [IO.StreamReader]::new($stream)
    $writer.WriteLine((@{ token = $endpointData.token; command = 'shutdown-for-update' } | ConvertTo-Json -Compress))
    $writer.Flush()
    return (($reader.ReadLine() | ConvertFrom-Json).ok -eq $true)
  } catch { return $false }
  finally { if ($client) { $client.Dispose() } }
}
try {
  if ($Phase -eq 'UnloadDriver') {
    if (@(OwnedProcesses).Count) { throw 'Owned processes still running' }
    UnloadOwnedWinDivert
    exit 0
  }
  if ($Phase -eq 'CheckDriver') {
    # Only a verified owned service may have been stopped by UnloadDriver.
    # An inaccessible changed driver still blocks setup before copying.
    $driver = Join-Path $prefix 'zapret\WinDivert64.sys'
    if (!(Test-Path -LiteralPath $driver)) { exit 0 }
    if (!(WaitUntil {
      try {
        $handle = [IO.File]::Open($driver, [IO.FileMode]::Open,
          [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $handle.Dispose()
        return $true
      } catch { return $false }
    } 10)) { throw 'WinDivert64.sys cannot be safely replaced; restart Windows' }
    exit 0
  }
  if ($Phase -eq 'Release') {
    if (!(Test-Path -LiteralPath $StateFile)) { exit 0 }
    $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if (!(OwnedService)) { throw 'Helper service identity changed during setup' }
    InvokeSc @('config', $ServiceName, 'start=', [string]$saved.start)
    if ($saved.running) {
      $s = OwnedService
      if ($s.State -ne 'Running') { InvokeSc @('start', $ServiceName) }
      if (!(WaitUntil { (OwnedService).State -eq 'Running' } 35)) { throw 'Helper failed to resume' }
    }
    Remove-Item -LiteralPath $StateFile -Force
    exit 0
  }
  $apps = @(OwnedProcesses | Where-Object Name -eq $AppExe)
  if ($apps.Count) {
    $ack = AskAppToExit
    $closeSent = $false
    if (!$ack) {
      # Compatibility with releases that lack the authenticated update command.
      foreach ($p in $apps) {
        $process = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($process -and $process.Path -and (InInstall $process.Path)) {
          if ($process.CloseMainWindow()) { $closeSent = $true }
        }
      }
    }
    $seconds = if ($ack -or $closeSent) { 45 } else { 8 }
    if (!(WaitUntil { @(OwnedProcesses | Where-Object Name -eq $AppExe).Count -eq 0 } $seconds)) {
      foreach ($p in @(OwnedProcesses | Where-Object Name -eq $AppExe)) { StopOwned $p }
    }
  }
  $service = OwnedService
  if ($service) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $reg = Get-ItemProperty -LiteralPath $key
    $start = switch ([int]$reg.Start) {
      2 { if ($reg.DelayedAutoStart -eq 1) { 'delayed-auto' } else { 'auto' } }
      3 { 'demand' }
      4 { 'disabled' }
      default { throw 'Unexpected Helper startup mode' }
    }
    # Preserve service startup policy on completion or cancellation.
    if (!(Test-Path -LiteralPath $StateFile)) {
      @{ start = $start; running = ($service.State -ne 'Stopped' -and $start -ne 'disabled') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $StateFile -Encoding ASCII
    }
    InvokeSc @('config', $ServiceName, 'start=', 'disabled')
    if ($service.State -ne 'Stopped' -and $service.State -ne 'Stop Pending') {
      & "$env:SystemRoot\System32\sc.exe" stop $ServiceName | Out-Host
    }
    if (!(WaitUntil { (OwnedService).State -eq 'Stopped' } 35)) {
      foreach ($p in @(OwnedProcesses | Where-Object Name -eq ($ServiceName + '.exe'))) { StopOwned $p }
      if (!(WaitUntil { (OwnedService).State -eq 'Stopped' } 10)) { throw 'Helper did not stop' }
    }
  }
  # Fallback for a crashed app, orphaned core or Zapret process.
  foreach ($p in @(OwnedProcesses)) { StopOwned $p }
  if (!(WaitUntil { @(OwnedProcesses).Count -eq 0 } 10)) { throw 'Installation files still in use' }
  exit 0
} catch {
  Write-Error $_ -ErrorAction Continue
  exit 1
}
