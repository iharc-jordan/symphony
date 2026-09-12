[CmdletBinding()]
param(
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows) -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
  throw 'Symphony managed releases are built only on Windows x64.'
}

$elixirRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $elixirRoot '..'))
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$versionMatch = Select-String -LiteralPath (Join-Path $elixirRoot 'mix.exs') -Pattern '^\s*version:\s*"([^"]+)"' | Select-Object -First 1

if (-not $versionMatch) {
  throw 'Unable to read the release version from mix.exs.'
}

$version = $versionMatch.Matches[0].Groups[1].Value
$artifactBase = "symphony-$version-windows-x64"
$stage = Join-Path $outputRoot $artifactBase
$archive = Join-Path $outputRoot "$artifactBase.zip"
$checksumFile = "$archive.sha256"
$manifestFile = Join-Path $outputRoot 'release-manifest.json'
$workerHostManifest = Join-Path $elixirRoot 'native\symphony_worker_host\Cargo.toml'
$workerHostBinary = Join-Path $elixirRoot 'native\symphony_worker_host\target\release\symphony-worker-host.exe'
$peInspector = Join-Path $elixirRoot 'scripts\inspect-pe-imports.mjs'

function Resolve-VcRuntimeRedist {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Visual Studio vswhere.exe is required to locate licensed VC runtime REDIST files.'
  }

  $installations = @(& $vswhere -all -products * -property installationPath) | Where-Object { $_ }
  foreach ($installation in $installations) {
    $redistRoot = Join-Path $installation 'VC\Redist\MSVC'
    if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) { continue }

    $versions = Get-ChildItem -LiteralPath $redistRoot -Directory | Sort-Object Name -Descending
    foreach ($candidateVersion in $versions) {
      $candidate = Get-ChildItem -LiteralPath (Join-Path $candidateVersion.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $candidate) { continue }

      $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
      $missingRequired = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidate.FullName $_) -PathType Leaf) })
      if ($missingRequired.Count -eq 0) {
        $redistList = Join-Path $installation 'Licenses\1033\Redist.txt'
        if (-not (Test-Path -LiteralPath $redistList -PathType Leaf)) {
          throw "Visual Studio REDIST list is missing: $redistList"
        }

        return [pscustomobject]@{
          Directory = $candidate.FullName
          Version = $candidateVersion.Name
          Files = $required
          RedistList = $redistList
        }
      }
    }
  }

  throw 'A licensed x64 Microsoft Visual C++ runtime REDIST directory was not found.'
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$expectedPrefix = $outputRoot.TrimEnd('\') + '\'
$resolvedStage = [System.IO.Path]::GetFullPath($stage)

if (-not $resolvedStage.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to clean release stage outside output directory: $resolvedStage"
}

if (Test-Path -LiteralPath $stage) {
  Remove-Item -LiteralPath $stage -Recurse -Force
}

foreach ($file in @($archive, $checksumFile, $manifestFile)) {
  if (Test-Path -LiteralPath $file) {
    Remove-Item -LiteralPath $file -Force
  }
}

$erlPath = (Get-Command erl.exe -ErrorAction Stop).Source
$otpRoot = Split-Path -Parent (Split-Path -Parent $erlPath)
$otpVersionFile = Get-ChildItem -LiteralPath (Join-Path $otpRoot 'releases') -Directory |
  ForEach-Object { Join-Path $_.FullName 'OTP_VERSION' } |
  Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
  Select-Object -First 1
if (-not $otpVersionFile) { throw 'Unable to read the embedded OTP version.' }
$otpVersion = (Get-Content -Raw -LiteralPath $otpVersionFile).Trim()
$otp = $otpVersion.Split('.')[0]
$elixir = (& elixir.bat --short-version).Trim()

if ($otp -ne '28' -or -not $elixir.StartsWith('1.19.')) {
  throw "Expected OTP 28 and Elixir 1.19.x, found OTP $otpVersion and Elixir $elixir."
}

Push-Location $elixirRoot
try {
  & cargo.exe build --locked --release --manifest-path $workerHostManifest
  if ($LASTEXITCODE -ne 0) { throw 'cargo build for symphony-worker-host failed.' }

  $env:MIX_ENV = 'prod'
  & mix.bat deps.get --only prod
  if ($LASTEXITCODE -ne 0) { throw 'mix deps.get failed.' }

  & mix.bat compile --warnings-as-errors
  if ($LASTEXITCODE -ne 0) { throw 'mix compile failed.' }

  & mix.bat release symphony --overwrite --path $stage
  if ($LASTEXITCODE -ne 0) { throw 'mix release failed.' }
}
finally {
  Pop-Location
}

$releaseLauncher = Join-Path $stage 'bin\symphony.bat'
$erts = Get-ChildItem -LiteralPath $stage -Directory -Filter 'erts-*' | Select-Object -First 1
$releaseEnvironment = Join-Path $stage "releases\$version\env.bat"
$releaseCookie = Join-Path $stage 'releases\COOKIE'

if (-not (Test-Path -LiteralPath $releaseLauncher -PathType Leaf) -or -not $erts -or
    -not (Test-Path -LiteralPath $releaseEnvironment -PathType Leaf)) {
  throw 'The staged release is missing bin\symphony.bat, env.bat, or embedded ERTS.'
}

$releaseEnvironmentContents = Get-Content -Raw -LiteralPath $releaseEnvironment
if ($releaseEnvironmentContents -notmatch '(?im)^set "RELEASE_DISTRIBUTION=none"\s*$' -or
    $releaseEnvironmentContents -notmatch '(?im)^set "RELEASE_COOKIE=codex_orchestration_local_only"\s*$') {
  throw 'The staged release must disable Erlang distribution and use the non-secret local cookie placeholder.'
}

if (Test-Path -LiteralPath $releaseCookie -PathType Leaf) {
  Remove-Item -LiteralPath $releaseCookie -Force
}

Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'NOTICE') -Destination (Join-Path $stage 'NOTICE')
Copy-Item -LiteralPath $workerHostBinary -Destination (Join-Path $stage 'bin\symphony-worker-host.exe')

if (-not (Test-Path -LiteralPath (Join-Path $stage 'bin\symphony-worker-host.exe') -PathType Leaf)) {
  throw 'The native Windows worker host was not staged.'
}

$vcRuntime = Resolve-VcRuntimeRedist
$debugRuntimeFiles = @(Get-ChildItem -LiteralPath $erts.FullName -Recurse -File | Where-Object { $_.Name -match '(?i)^beam\.debug\..*\.dll$|\.pdb$' })
foreach ($debugRuntimeFile in $debugRuntimeFiles) {
  Remove-Item -LiteralPath $debugRuntimeFile.FullName -Force
}

$importingPeFiles = @(
  Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object { $_.Extension -in '.dll', '.exe' } |
    Select-Object -ExpandProperty FullName
)

if ($importingPeFiles.Count -lt 3) {
  throw 'The staged release does not contain the expected Windows PE runtime files.'
}

$peImports = @(& node.exe $peInspector @importingPeFiles)
if ($LASTEXITCODE -ne 0 -or $peImports.Count -ne $importingPeFiles.Count) {
  throw 'PE import inspection failed.'
}

$bundledVcFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in $peImports) {
  $entry = $line | ConvertFrom-Json
  $requiredImports = @($entry.imports | Where-Object { $_ -match '(?i)^(msvcp|vcruntime|concrt)\d.*\.dll$' })
  foreach ($dependency in $requiredImports) {
    $sourceDependency = Join-Path $vcRuntime.Directory $dependency
    if (-not (Test-Path -LiteralPath $sourceDependency -PathType Leaf)) {
      throw "The licensed REDIST directory does not contain imported VC runtime dependency $dependency for $($entry.file)."
    }

    Copy-Item -LiteralPath $sourceDependency -Destination (Join-Path (Split-Path -Parent $entry.file) $dependency) -Force
    [void]$bundledVcFiles.Add($dependency)
  }

  $missing = @($requiredImports | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $entry.file) $_) -PathType Leaf) })
  if ($missing.Count -ne 0) {
    throw "App-local VC runtime dependencies are missing beside $($entry.file): $($missing -join ', ')"
  }
}

$thirdParty = Join-Path $stage 'third_party\microsoft-vc-runtime'
New-Item -ItemType Directory -Force -Path $thirdParty | Out-Null
Copy-Item -LiteralPath $vcRuntime.RedistList -Destination (Join-Path $thirdParty 'Redist.txt')

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -CompressionLevel Optimal
$digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$digest  $([System.IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath $checksumFile -Encoding ascii

$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$manifest = [ordered]@{
  schemaVersion = 1
  product = 'Codex Orchestration Symphony'
  repository = 'iharc-jordan/symphony'
  version = $version
  platform = 'windows-x64'
  sourceRepository = 'https://github.com/iharc-jordan/symphony'
  sourceCommit = $sourceCommit
  runtimeArchive = [System.IO.Path]::GetFileName($archive)
  runtimeDownloadUrl = "https://github.com/iharc-jordan/symphony/releases/download/v$version/$([System.IO.Path]::GetFileName($archive))"
  offlineArchive = [System.IO.Path]::GetFileName($archive)
  sha256 = $digest
  otp = "$otpVersion ($($erts.Name))"
  elixir = $elixir
  distribution = 'none'
  cookieFile = 'absent'
  vcRuntime = [ordered]@{
    version = $vcRuntime.Version
    files = @($bundledVcFiles | Sort-Object)
    deployment = 'app-local beside each importing PE'
  }
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestFile -Encoding utf8NoBOM
Write-Output $archive
Write-Output $checksumFile
Write-Output $manifestFile
