$ErrorActionPreference = 'Stop'
if (!$env:FLCLASHZ_TEST_SIGNED_CORE_DIR) { throw 'Missing verified package' }
$messages = cargo test --locked --manifest-path services/helper/Cargo.toml --features windows-service --no-run --message-format=json
if ($LASTEXITCODE -ne 0) { throw 'Helper test build failed' }
$testExe = @($messages | ForEach-Object {
  try {
    $m = $_ | ConvertFrom-Json -ErrorAction Stop
    if ($m.reason -eq 'compiler-artifact' -and $m.target.name -eq 'helper' -and $m.profile.test -and $m.executable) { $m.executable }
  } catch {}
})
if ($testExe.Count -ne 1) { throw 'Could not identify the Helper test executable' }
$dir = Join-Path $env:RUNNER_TEMP ('core-system-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
Copy-Item $testExe[0] (Join-Path $dir 'helper-test.exe')
Copy-Item (Join-Path $env:FLCLASHZ_TEST_SIGNED_CORE_DIR 'core-manifest.json') $dir
Copy-Item (Join-Path $env:FLCLASHZ_TEST_SIGNED_CORE_DIR 'FlClashCore.exe') $dir
$script = Join-Path $dir 'run.ps1'
@'
$ErrorActionPreference = 'Stop'
$env:FLCLASHZ_SYSTEM_CORE_TEST_DIR = $PSScriptRoot
$env:RUST_BACKTRACE = '1'
try {
  if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Not LocalSystem' }
  & (Join-Path $PSScriptRoot 'helper-test.exe') --exact service::hub::tests::published_z3_system_stage_launch_and_loopback --nocapture *> (Join-Path $PSScriptRoot 'result.log')
  $code = $LASTEXITCODE
} catch {
  $_ | Out-File -Append (Join-Path $PSScriptRoot 'result.log')
  $code = 1
}
Set-Content (Join-Path $PSScriptRoot 'exit.txt') $code
exit $code
'@ | Set-Content -Encoding UTF8 $script
$name = 'FlClashZ-core-smoke-' + [Guid]::NewGuid().ToString('N')
try {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -File "' + $script + '"')
  Register-ScheduledTask -TaskName $name -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName $name
  $deadline = [DateTime]::UtcNow.AddMinutes(4)
  $marker = Join-Path $dir 'exit.txt'
  while (!(Test-Path $marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 2 }
  $log = Join-Path $dir 'result.log'
  if (Test-Path $log) { Get-Content $log | Write-Host }
  if (!(Test-Path $marker)) { throw 'SYSTEM smoke timed out' }
  if ((Get-Content $marker -Raw).Trim() -ne '0' -or !(Select-String -Path $log -SimpleMatch 'SYSTEM protected slot, tamper rejection, managed launch, live IPC and loopback proxy passed.')) { throw 'SYSTEM smoke failed or test did not execute' }
} finally {
  Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
