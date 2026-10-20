<#
.SYNOPSIS
  Packs a finished `flutter build windows --release` into an Inno Setup
  installer, plus a sha256sum-style checksum file next to it.

.DESCRIPTION
  Run from anywhere after the Windows release build. Used both locally and by
  .github/workflows/build-release.yml. Needs Inno Setup 6 (ISCC.exe): found
  through $env:ISCC, PATH, or the default per-user / per-machine install
  folders (`winget install JRSoftware.InnoSetup` puts it in one of them).

.PARAMETER Channel
  The BUILD_CHANNEL the app was built with: stable, nightly, or a test name.
  Must match the build, since it picks the install folder and the data folder
  the uninstaller offers to delete.

.PARAMETER Version
  Defaults to `version:` in pubspec.yaml without its `+build` suffix.

.PARAMETER BaseName
  Installer file name without `.exe`. Defaults to
  `Glaze-<channel>-<version>-windows-setup`.
#>
param(
  [string]$Channel = 'nightly',
  [string]$Version = '',
  [string]$SourceDir = '',
  [string]$OutputDir = '',
  [string]$BaseName = ''
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if (-not $Version) {
  $line = Select-String -Path (Join-Path $repo 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
  if (-not $line) { throw 'No version: line in pubspec.yaml' }
  $Version = $line.Matches[0].Groups[1].Value -replace '\+.*$', ''
}
$Version = $Version.TrimStart('v', 'V')
# VERSIONINFO only takes dotted numbers: 0.9.1-rc1 is stamped as 0.9.1.
$numeric = ($Version -replace '[-+].*$', '')
if ($numeric -notmatch '^\d+(\.\d+){0,3}$') { throw "Version '$Version' is not numeric-dotted" }

if (-not $SourceDir) { $SourceDir = Join-Path $repo 'build\windows\x64\runner\Release' }
if (-not $OutputDir) { $OutputDir = Join-Path $repo 'build\windows\installer' }
$SourceDir = (Resolve-Path $SourceDir).Path
if (-not (Test-Path (Join-Path $SourceDir 'Glaze.exe'))) {
  throw "Glaze.exe not found in $SourceDir - run flutter build windows --release first"
}
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
if (-not $BaseName) { $BaseName = "Glaze-$Channel-$Version-windows-setup" }

$iscc = $env:ISCC
if (-not $iscc) {
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
  $iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $iscc) { throw 'ISCC.exe (Inno Setup 6) not found; set $env:ISCC or install JRSoftware.InnoSetup' }

& $iscc /Q `
  "/DAppVersion=$Version" `
  "/DNumericVersion=$numeric" `
  "/DChannel=$Channel" `
  "/DSourceDir=$SourceDir" `
  "/DOutputDir=$OutputDir" `
  "/DOutputBaseFilename=$BaseName" `
  (Join-Path $PSScriptRoot 'glaze.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Join-Path $OutputDir "$BaseName.exe"
$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
# `<hash>  <file>`, the format sha256sum -c reads. The in-app updater prefers
# the digest GitHub reports for the asset and falls back to this file.
[IO.File]::WriteAllText("$setup.sha256", "$hash  $BaseName.exe`n")
Write-Output $setup
