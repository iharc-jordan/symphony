param(
  [string]$HelperPath = (Join-Path $PSScriptRoot '..\target\debug\symphony-worker-host.exe')
)

$ErrorActionPreference = 'Stop'
$HelperPath = [IO.Path]::GetFullPath($HelperPath)
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
  throw "Build the helper first: $HelperPath"
}

$testRoot = Join-Path $env:TEMP ("symphony-worker-host-test-" + [guid]::NewGuid())
$identityPath = Join-Path $testRoot 'identity.json'
$descendantPidPath = Join-Path $testRoot 'descendant.pid'
$jobName = 'symphony-test-' + [guid]::NewGuid().ToString('N')
$fixtureProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Start-Worker([string[]]$Arguments) {
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $HelperPath
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $info.Arguments = ($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
  $process = [Diagnostics.Process]::Start($info)
  [void]$fixtureProcesses.Add($process)
  return $process
}

function Wait-FixtureFile([string]$Path, [string]$Failure) {
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ((-not (Test-Path -LiteralPath $Path)) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
  if (-not (Test-Path -LiteralPath $Path)) { throw $Failure }
}

function Assert-ProcessGone([int]$ProcessId, [string]$Failure) {
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
  if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { throw $Failure }
}

try {
  $descendantScript = "`$child = Start-Process -FilePath `$env:ComSpec -ArgumentList '/d','/s','/c','timeout /t 30 /nobreak >NUL' -WindowStyle Hidden -PassThru; `$child.Id | Set-Content -LiteralPath '$($descendantPidPath.Replace("'", "''"))'; Start-Sleep -Seconds 30"
  $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($descendantScript))
  $workerArgs = @('--parent-pid', $PID, '--job-name', $jobName, '--identity-file', $identityPath, '--cwd', $testRoot, '--attempt-id', 'attempt-job-regression', '--', (Get-Command powershell).Source, '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedScript)
  $worker = Start-Worker $workerArgs

  Wait-FixtureFile $identityPath 'helper did not persist its process identity'
  Wait-FixtureFile $descendantPidPath 'worker did not create its descendant'

  $identity = Get-Content -Raw -LiteralPath $identityPath | ConvertFrom-Json
  $descendantPid = [int](Get-Content -Raw -LiteralPath $descendantPidPath)
  $unrelated = Start-Process -FilePath $env:ComSpec -ArgumentList '/d','/s','/c','timeout /t 30 /nobreak >NUL' -WindowStyle Hidden -PassThru
  [void]$fixtureProcesses.Add($unrelated)

  # A mismatched creation time simulates PID reuse. It must not terminate the
  # active worker job or an unrelated process.
  & $HelperPath --stop --job-name $identity.job_name --pid $identity.child_pid --creation-time ([uint64]$identity.child_creation_time + 1)
  if ($LASTEXITCODE -eq 0) { throw 'PID-reuse guard unexpectedly accepted a mismatched identity' }
  if ($worker.HasExited) { throw 'mismatched identity terminated the worker' }
  if ($unrelated.HasExited) { throw 'mismatched identity affected an unrelated process' }

  & $HelperPath --stop --job-name $identity.job_name --pid $identity.child_pid --creation-time $identity.child_creation_time
  if ($LASTEXITCODE -ne 0) { throw 'verified Job Object termination failed' }
  if (-not $worker.WaitForExit(5000)) { throw 'helper did not exit after its owned job terminated' }
  Assert-ProcessGone $descendantPid 'owned Job Object descendant survived termination'
  if ($unrelated.HasExited) { throw 'owned Job Object termination affected an unrelated process' }

  $helperCrashIdentityPath = Join-Path $testRoot 'helper-crash-identity.json'
  $helperCrashDescendantPath = Join-Path $testRoot 'helper-crash-descendant.pid'
  $helperCrashJob = 'symphony-helper-crash-' + [guid]::NewGuid().ToString('N')
  $helperCrashScript = "`$child = Start-Process -FilePath `$env:ComSpec -ArgumentList '/d','/s','/c','timeout /t 30 /nobreak >NUL' -WindowStyle Hidden -PassThru; `$child.Id | Set-Content -LiteralPath '$($helperCrashDescendantPath.Replace("'", "''"))'; Start-Sleep -Seconds 30"
  $helperCrashEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCrashScript))
  $helperCrashArgs = @('--parent-pid', $PID, '--job-name', $helperCrashJob, '--identity-file', $helperCrashIdentityPath, '--cwd', $testRoot, '--attempt-id', 'attempt-helper-crash', '--', (Get-Command powershell).Source, '-NoProfile', '-NonInteractive', '-EncodedCommand', $helperCrashEncoded)
  $helperCrashWorker = Start-Worker $helperCrashArgs
  Wait-FixtureFile $helperCrashIdentityPath 'helper-crash fixture did not persist identity'
  Wait-FixtureFile $helperCrashDescendantPath 'helper-crash fixture did not create its descendant'
  $helperCrashIdentity = Get-Content -Raw -LiteralPath $helperCrashIdentityPath | ConvertFrom-Json
  $helperCrashDescendantPid = [int](Get-Content -Raw -LiteralPath $helperCrashDescendantPath)
  Stop-Process -InputObject $helperCrashWorker -Force
  if (-not $helperCrashWorker.WaitForExit(5000)) { throw 'forced helper crash did not exit' }
  Assert-ProcessGone ([int]$helperCrashIdentity.child_pid) 'worker survived helper crash despite kill-on-close'
  Assert-ProcessGone $helperCrashDescendantPid 'descendant survived helper crash despite kill-on-close'

  $parentCrashIdentityPath = Join-Path $testRoot 'parent-crash-identity.json'
  $parentCrashDescendantPath = Join-Path $testRoot 'parent-crash-descendant.pid'
  $parentCrashJob = 'symphony-parent-crash-' + [guid]::NewGuid().ToString('N')
  $parentSentinel = Start-Process -FilePath (Get-Command powershell).Source -ArgumentList '-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  [void]$fixtureProcesses.Add($parentSentinel)
  $parentCrashScript = "`$child = Start-Process -FilePath `$env:ComSpec -ArgumentList '/d','/s','/c','timeout /t 30 /nobreak >NUL' -WindowStyle Hidden -PassThru; `$child.Id | Set-Content -LiteralPath '$($parentCrashDescendantPath.Replace("'", "''"))'; Start-Sleep -Seconds 30"
  $parentCrashEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCrashScript))
  $parentCrashArgs = @('--parent-pid', $parentSentinel.Id, '--job-name', $parentCrashJob, '--identity-file', $parentCrashIdentityPath, '--cwd', $testRoot, '--attempt-id', 'attempt-parent-crash', '--', (Get-Command powershell).Source, '-NoProfile', '-NonInteractive', '-EncodedCommand', $parentCrashEncoded)
  $parentCrashWorker = Start-Worker $parentCrashArgs
  Wait-FixtureFile $parentCrashIdentityPath 'parent-crash fixture did not persist identity'
  Wait-FixtureFile $parentCrashDescendantPath 'parent-crash fixture did not create its descendant'
  $parentCrashIdentity = Get-Content -Raw -LiteralPath $parentCrashIdentityPath | ConvertFrom-Json
  $parentCrashDescendantPid = [int](Get-Content -Raw -LiteralPath $parentCrashDescendantPath)
  Stop-Process -InputObject $parentSentinel -Force
  if (-not $parentSentinel.WaitForExit(5000)) { throw 'parent sentinel did not exit' }
  if (-not $parentCrashWorker.WaitForExit(5000)) { throw 'helper did not exit after parent crash' }
  Assert-ProcessGone ([int]$parentCrashIdentity.child_pid) 'worker survived parent crash monitor termination'
  Assert-ProcessGone $parentCrashDescendantPid 'descendant survived parent crash monitor termination'

  $exitIdentity = Join-Path $testRoot 'exit-identity.json'
  $exitJob = 'symphony-exit-test-' + [guid]::NewGuid().ToString('N')
  $exitArgs = @('--parent-pid', $PID, '--job-name', $exitJob, '--identity-file', $exitIdentity, '--cwd', $testRoot, '--attempt-id', 'attempt-exit-regression', '--', (Get-Command powershell).Source, '-NoProfile', '-NonInteractive', '-Command', 'exit 17')
  $exitWorker = Start-Worker $exitArgs
  if (-not $exitWorker.WaitForExit(5000)) { throw 'exit-code fixture did not finish' }
  if ($exitWorker.ExitCode -ne 17) { throw "helper replaced child exit 17 with $($exitWorker.ExitCode)" }

  Write-Output 'Windows Job Object stop, PID-reuse, unrelated-process, helper-crash, parent-crash, and child-exit propagation regression passed.'
}
finally {
  foreach ($fixtureProcess in $fixtureProcesses) {
    try {
      $fixtureProcess.Refresh()
      if (-not $fixtureProcess.HasExited) {
        Stop-Process -InputObject $fixtureProcess -Force
        [void]$fixtureProcess.WaitForExit(5000)
      }
    }
    catch { }
  }
  if (Test-Path -LiteralPath $testRoot) {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $expectedPrefix = $resolvedTempRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTestRoot) -notmatch '^symphony-worker-host-test-[0-9a-f-]{36}$') {
      throw "refusing fixture cleanup outside the verified temporary root: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
