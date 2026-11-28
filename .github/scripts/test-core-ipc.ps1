param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$true)][string]$Engine,
  [Parameter(Mandatory=$true)][string]$HostRevision
)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Exe).Path
$pipeName = 'flclashz-core-smoke-' + [Guid]::NewGuid().ToString('N')
$pipe = [System.IO.Pipes.NamedPipeServerStream]::new($pipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
$process = $null
$script:requestId = 0
function Read-Exact([int]$length) {
  $buffer = [byte[]]::new($length)
  $offset = 0
  while ($offset -lt $length) {
    $task = $pipe.ReadAsync($buffer, $offset, $length - $offset)
    if (!$task.Wait(10000)) { throw 'IPC read timeout' }
    $n = $task.GetAwaiter().GetResult()
    if ($n -le 0) { throw 'IPC peer closed' }
    $offset += $n
  }
  return ,$buffer
}
function Invoke-Core([string]$method, $arguments = $null, [switch]$ExpectError) {
  $script:requestId++
  $id = [string]$script:requestId
  $json = @{ id=$id; method=$method; arguments=$arguments } | ConvertTo-Json -Compress -Depth 12
  $payload = [Text.Encoding]::UTF8.GetBytes($json)
  $header = [BitConverter]::GetBytes([uint32]$payload.Length)
  $pipe.Write($header,0,4)
  $pipe.Write($payload,0,$payload.Length)
  $pipe.Flush()
  for ($i=0; $i -lt 100; $i++) {
    $size = [BitConverter]::ToUInt32((Read-Exact 4),0)
    if ($size -eq 0 -or $size -gt 8388608) { throw 'Invalid smoke response frame' }
    $response = [Text.Encoding]::UTF8.GetString((Read-Exact ([int]$size))) | ConvertFrom-Json
    if ($response.method -eq 'message') { continue }
    if ($response.id -cne $id) { throw "Unexpected RPC reply ID: $($response.id)" }
    if ($ExpectError) {
      if (!$response.error) { throw "$method unexpectedly succeeded" }
      return $response.error
    }
    if ($response.error) { throw "$method failed: $($response.error.message)" }
    return ,$response.result
  }
  throw "No response for $method"
}
try {
  $start = [Diagnostics.ProcessStartInfo]::new($exe)
  $start.UseShellExecute = $false
  $start.ArgumentList.Add("\\.\pipe\$pipeName")
  $process = [Diagnostics.Process]::Start($start)
  $connect = $pipe.WaitForConnectionAsync()
  if (!$connect.Wait(15000)) { throw 'Core did not connect to the Windows named pipe' }
  $connect.GetAwaiter().GetResult()
  $identity = Invoke-Core 'getCoreIdentity'
  if ($identity.version -cne $Version -or $identity.engineRevision -cne $Engine -or $identity.hostRevision -cne $HostRevision) { throw 'Live IPC identity does not match executable metadata' }
  $capabilities = Invoke-Core 'getCoreCapabilities'
  foreach ($required in @('closed-flow-history-v1','chain-diagnostics-v1','dns-stages-v1','core-identity-v1','adaptive-balance-v1','chain-health-v1')) {
    if ($capabilities -cnotcontains $required) { throw "Missing live capability: $required" }
  }
  # The z.3 adapter must advertise the atomic Windows profile contract.
  if ($capabilities -cnotcontains 'atomic-profile-apply-v1') { throw 'Missing atomic Windows profile capability' }
  $started = Invoke-Core 'startListener'
  if ($started -ne $false) { throw 'Core started listeners without an accepted profile' }
  $settings = Invoke-Core 'setEngineDiagnostics' @{closedFlowCapacity=8; chainDiagnostics=$true}
  if ($settings.closedFlowCapacity -ne 8 -or !$settings.chainDiagnostics) { throw 'Native settings not applied' }
  $snapshot = Invoke-Core 'getEngineDiagnostics'
  if ($snapshot.settings.closedFlowCapacity -ne 8 -or $null -eq $snapshot.closed -or $null -eq $snapshot.chains) { throw 'Invalid native snapshot' }
  $invalid = Invoke-Core 'setEngineDiagnostics' @{closedFlowCapacity=1025; chainDiagnostics=$false} -ExpectError
  $snapshot = Invoke-Core 'getEngineDiagnostics'
  if ($snapshot.settings.closedFlowCapacity -ne 8 -or !$snapshot.settings.chainDiagnostics) { throw 'Invalid request mutated diagnostic settings' }
  $chain = Invoke-Core 'getChainHealth'
  if (!$chain.available -or $null -eq $chain.owners -or $null -eq $chain.jobs) { throw 'Native chain contract unavailable' }
  $unknown = Invoke-Core 'unknown-smoke-method' -ExpectError
  if ($unknown.code -cne 'not_implemented') { throw 'Unexpected unknown method contract' }
  $settings = Invoke-Core 'setEngineDiagnostics' @{closedFlowCapacity=0; chainDiagnostics=$false}
  if ($settings.closedFlowCapacity -ne 0 -or $settings.chainDiagnostics) { throw 'Native diagnostics did not stop' }
  Write-Host 'Real Windows named-pipe identity, capabilities, native settings, bounds and error contracts passed.'
} finally {
  $pipe.Dispose()
  if ($process) {
    if (!$process.WaitForExit(10000)) { $process.Kill($true); $process.WaitForExit(); throw 'Core failed to exit after pipe closure' }
    if ($process.ExitCode -ne 0) { throw "Core exited with $($process.ExitCode)" }
    $process.Dispose()
  }
}
