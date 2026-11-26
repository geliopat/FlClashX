param([string]$Bundle = '', [switch]$RequireExistingConsent)
$ErrorActionPreference = 'Stop'
if (!$Bundle) {
  $Bundle = @('build/windows/x64/runner/Release', 'build/windows/runner/Release') |
    Where-Object { Test-Path (Join-Path $_ 'FlClashZ.exe') } | Select-Object -First 1
}
if (!$Bundle) { throw 'Windows Release bundle not found' }
$Bundle = (Resolve-Path $Bundle).Path
foreach ($name in @('FlClashZ.exe', 'FlClashCore.exe', 'FlClashZHelperService.exe', 'flutter_windows.dll', 'manifest.json', 'data/app.so', 'data/icudtl.dat', 'zapret/winws.exe', 'zapret/winws2.exe')) {
  if (!(Test-Path (Join-Path $Bundle $name))) { throw "Missing bundle component: $name" }
}
# The Windows path provider derives the app data subdirectory from these
# version resource values. Reject an accidental upstream identity.
$versionInfo = (Get-Item -LiteralPath (Join-Path $Bundle 'FlClashZ.exe')).VersionInfo
if ($versionInfo.LegalCopyright -notmatch 'sweetyyoba\.com') { throw 'Unexpected copyright resource' }
if ($versionInfo.CompanyName -ne 'sweetyyoba.com' -or $versionInfo.ProductName -ne 'clashz') {
  throw "Unexpected application data identity: $($versionInfo.CompanyName)/$($versionInfo.ProductName)"
}
$marker = Join-Path $env:RUNNER_TEMP ("flclashz-smoke-" + [guid]::NewGuid() + ".txt")
$previous = $env:FLCLASHZ_SMOKE_MARKER
$previousConsent = $env:FLCLASH_ACCEPT_DISCLAIMER
if ($RequireExistingConsent) {
  $consent = Join-Path $env:APPDATA 'sweetyyoba.com\clashz\disclaimer.accepted'
  if (!(Test-Path -LiteralPath $consent) -or (Get-Content -LiteralPath $consent -Raw).Trim() -ne '1') { throw 'Expected consent from previous portable launch' }
  Remove-Item Env:FLCLASH_ACCEPT_DISCLAIMER -ErrorAction SilentlyContinue
} else {
  $env:FLCLASH_ACCEPT_DISCLAIMER = '1'
}
$env:FLCLASHZ_SMOKE_MARKER = $marker
$process = $null
try {
  $process = Start-Process -FilePath (Join-Path $Bundle 'FlClashZ.exe') -ArgumentList '--ci-smoke-test' -WorkingDirectory $Bundle -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  while ([DateTime]::UtcNow -lt $deadline) {
    $process.Refresh()
    if ($process.HasExited) { throw "Application exited before startup acknowledgement: $($process.ExitCode)" }
    if (Test-Path -LiteralPath $marker) {
      # The acknowledgement is written after a rendered frame. A partial
      # write is not a valid acknowledgement; allow the next polling cycle.
      $actual = $null
      try { $actual = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch {}
      if (!$actual -or $actual.status -ne 'first-frame-ok') {
        Start-Sleep -Milliseconds 500
        continue
      }
      $home = Join-Path $env:APPDATA 'sweetyyoba.com\clashz'
      $cache = Join-Path $env:LOCALAPPDATA 'sweetyyoba.com\clashz'
      $expected = @{
        home = $home
        cache = $cache
        preferences = (Join-Path $home 'shared_preferences.json')
        database = (Join-Path $home 'database.sqlite')
        config = (Join-Path $home 'config.yaml')
        profiles = (Join-Path $home 'profiles')
        providers = (Join-Path $home 'providers')
        scripts = (Join-Path $home 'scripts')
        lock = (Join-Path $home 'FlClash.lock')
        coreCli = (Join-Path $home 'core-cli.json')
      }
      foreach ($key in $expected.Keys) {
        if ($actual.$key -ne $expected[$key]) {
          throw "Incorrect resolved data path ($key): $($actual.$key); expected $($expected[$key])"
        }
      }
      if (!(Test-Path -LiteralPath $home -PathType Container) -or
          !(Test-Path -LiteralPath $cache -PathType Container)) {
        throw 'Resolved application data directories do not exist'
      }
      $consent = Join-Path $home 'disclaimer.accepted'
      if (!(Test-Path -LiteralPath $consent) -or (Get-Content -LiteralPath $consent -Raw).Trim() -ne '1') {
        Start-Sleep -Milliseconds 500
        continue
      }
      Write-Host 'Roaming and Local AppData paths and persisted consent passed'
      Start-Sleep -Seconds 3
      $process.Refresh()
      if ($process.HasExited) { throw 'Application exited after its first frame' }
      Write-Host 'Windows startup and first Flutter frame passed'
      return
    }
    Start-Sleep -Milliseconds 500
  }
  throw 'Timed out waiting for the first Flutter frame'
} finally {
  if ($process) {
    $process.Refresh()
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    $process.Dispose()
  }
  if (Test-Path $marker) { Remove-Item -LiteralPath $marker -Force }
  $env:FLCLASHZ_SMOKE_MARKER = $previous
  $env:FLCLASH_ACCEPT_DISCLAIMER = $previousConsent
}
