param([string]$Bundle = '')
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
if ($versionInfo.CompanyName -ne 'sweetyyoba.com' -or $versionInfo.ProductName -ne 'clashz') {
  throw "Unexpected application data identity: $($versionInfo.CompanyName)/$($versionInfo.ProductName)"
}
$marker = Join-Path $env:RUNNER_TEMP ("flclashz-smoke-" + [guid]::NewGuid() + ".txt")
$previous = $env:FLCLASHZ_SMOKE_MARKER
$env:FLCLASHZ_SMOKE_MARKER = $marker
$process = $null
try {
  $process = Start-Process -FilePath (Join-Path $Bundle 'FlClashZ.exe') -ArgumentList '--ci-smoke-test' -WorkingDirectory $Bundle -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  while ([DateTime]::UtcNow -lt $deadline) {
    $process.Refresh()
    if ($process.HasExited) { throw "Application exited before startup acknowledgement: $($process.ExitCode)" }
    if ((Test-Path $marker) -and ((Get-Content -LiteralPath $marker -Raw) -eq 'first-frame-ok')) {
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
}
