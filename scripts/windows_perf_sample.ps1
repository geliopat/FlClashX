# Run in a dedicated Windows test VM. No processes are started or stopped.
param(
  [Parameter(Mandatory)][ValidateSet('v1.1.4','v1.1.5')] [string]$Version,
  [Parameter(Mandatory)][string]$Commit,
  [Parameter(Mandatory)][int]$GuiPid,
  [Parameter(Mandatory)][string]$Scenario,
  [Parameter(Mandatory)][string]$Output,
  [ValidateRange(10,1800)][int]$Seconds = 60,
  [ValidateRange(250,10000)][int]$IntervalMs = 1000
)
$ErrorActionPreference = 'Stop'
$gui = Get-Process -Id $GuiPid
if ($gui.ProcessName -ne 'FlClashZ' -or !$gui.Path) { throw 'Select the exact FlClashZ GUI PID' }
$bundle = Split-Path -Parent $gui.Path
$hash = (Get-FileHash -LiteralPath $gui.Path -Algorithm SHA256).Hash
$names = @{'FlClashZ'='GUI';'FlClashCore'='Mihomo';'FlClashZHelperService'='Helper';'winws'='Zapret';'winws2'='Zapret'}
$cpuCount = [Environment]::ProcessorCount
$prev = @{}
$rows = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
  $at = $clock.Elapsed.TotalSeconds
  foreach ($process in Get-Process -Name @($names.Keys) -ErrorAction SilentlyContinue) {
    try {
      if (!$process.Path -or !$process.Path.StartsWith($bundle + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
      if ($process.ProcessName -eq 'FlClashZ' -and $process.Id -ne $GuiPid) { continue }
      $identity = "$($process.Id):$($process.StartTime.Ticks)"
      $cpu = $process.TotalProcessorTime.TotalSeconds
      $previous = $prev[$identity]
      $percent = $null
      if ($previous -and $at -gt $previous.At) {
        $percent = 100 * ($cpu - $previous.Cpu) / ($at - $previous.At) / $cpuCount
      }
      $prev[$identity] = @{At=$at;Cpu=$cpu}
      $rows.Add([pscustomobject]@{
        version=$Version;commit=$Commit;guiSha256=$hash;scenario=$Scenario
        seconds=[Math]::Round($at,3);component=$names[$process.ProcessName];pid=$process.Id
        cpuPercentOfMachine=$percent;workingSetBytes=$process.WorkingSet64;privateBytes=$process.PrivateMemorySize64
      })
    } catch {
      # A process may exit between enumeration and reading. Do not invent zeroes.
    } finally { $process.Dispose() }
  }
  Start-Sleep -Milliseconds $IntervalMs
}
if (!$rows.Count) { throw 'No matching samples' }
$rows | Export-Csv -LiteralPath $Output -NoTypeInformation -Encoding UTF8
$os = Get-CimInstance Win32_OperatingSystem
$cpuInfo = Get-CimInstance Win32_Processor
[pscustomobject]@{
  version=$Version;commit=$Commit;scenario=$Scenario;guiSha256=$hash
  os=$os.Caption;osBuild=$os.BuildNumber;cpu=@($cpuInfo.Name);logicalProcessors=$cpuCount
  memoryBytes=[long]$os.TotalVisibleMemorySize * 1024
  durationSeconds=$Seconds;intervalMs=$IntervalMs
  components=@($rows | Select-Object -ExpandProperty component -Unique)
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$Output.metadata.json" -Encoding UTF8
