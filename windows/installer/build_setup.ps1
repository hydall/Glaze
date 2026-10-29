<#
.SYNOPSIS
  Packs a finished `flutter build windows --release` of Glaze into one
  GlazeSetup.exe, plus a sha256sum-style checksum file next to it.

.DESCRIPTION
  Run after the Glaze build, from anywhere; used locally and by both build
  workflows. Needs Flutter, CMake and the Visual Studio C++ tools, all of
  which the Glaze Windows build already needs.

    1. zips the Glaze Release folder (its WebView2 profile left out),
    2. builds the setup window (windows/installer/app) with the same channel,
       version and commit as the Glaze build,
    3. builds the launcher and the packer (windows/installer/launcher),
    4. packs launcher + window + zip into one file and checks it unpacks.

  See docs/WINDOWS_INSTALLER.md.

.PARAMETER Channel
  The BUILD_CHANNEL Glaze was built with. Picks the install folder, the Apps
  entry and the data folder the uninstaller offers to delete.

.PARAMETER Version
  Defaults to `version:` in pubspec.yaml without its `+build` suffix.

.PARAMETER Commit
  The commit Glaze was built from; shown on nightly setups.

.PARAMETER BaseName
  Setup file name without `.exe`. Defaults to
  `Glaze-<channel>-<version>-windows-setup`. The in-app updater looks for an
  asset whose name ends in `-windows-setup.exe`.
#>
param(
  [string]$Channel = 'nightly',
  [string]$Version = '',
  [string]$Commit = '',
  [string]$SourceDir = '',
  [string]$OutputDir = '',
  [string]$BaseName = ''
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app = Join-Path $PSScriptRoot 'app'
$launcher = Join-Path $PSScriptRoot 'launcher'

function Invoke-Checked([string]$what, [scriptblock]$block) {
  & $block
  if ($LASTEXITCODE -ne 0) { throw "$what failed with exit code $LASTEXITCODE" }
}

if (-not $Version) {
  $line = Select-String -Path (Join-Path $repo 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
  if (-not $line) { throw 'No version: line in pubspec.yaml' }
  $Version = $line.Matches[0].Groups[1].Value -replace '\+.*$', ''
}
$Version = $Version.TrimStart('v', 'V')

if (-not $SourceDir) { $SourceDir = Join-Path $repo 'build\windows\x64\runner\Release' }
if (-not $OutputDir) { $OutputDir = Join-Path $repo 'build\windows\setup' }
$SourceDir = (Resolve-Path $SourceDir).Path
if (-not (Test-Path (Join-Path $SourceDir 'Glaze.exe'))) {
  throw "Glaze.exe not found in $SourceDir - run flutter build windows --release first"
}
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
if (-not $BaseName) { $BaseName = "Glaze-$Channel-$Version-windows-setup" }

$work = Join-Path $repo 'build\windows\setup-work'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null

# ── 1. the Glaze build, zipped ───────────────────────────────────────────────
# Entry by entry rather than ZipFile.CreateFromDirectory: a Release folder the
# build was run from holds a WebView2 profile, which must not ship — an update
# would overwrite the user's own logins with it.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $work 'glaze.zip'
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  Get-ChildItem -LiteralPath $SourceDir -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($SourceDir.Length).TrimStart('\').Replace('\', '/')
    if ($relative -like 'Glaze.exe.WebView2/*') { return }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $zip, $_.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal)
  }
} finally {
  $zip.Dispose()
}

# ── 2. the setup window ──────────────────────────────────────────────────────
# Same font as the app, without a second copy in git.
New-Item -ItemType Directory -Force (Join-Path $app 'assets\fonts') | Out-Null
Copy-Item (Join-Path $repo 'assets\fonts\InterVariable.ttf') (Join-Path $app 'assets\fonts\') -Force
Push-Location $app
try {
  Invoke-Checked 'flutter pub get (setup)' { flutter pub get }
  Invoke-Checked 'flutter build windows (setup)' {
    flutter build windows --release --no-pub `
      "--dart-define=BUILD_CHANNEL=$Channel" `
      "--dart-define=APP_VERSION=$Version" `
      "--dart-define=BUILD_COMMIT=$Commit"
  }
} finally {
  Pop-Location
}
$window = Join-Path $app 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $window 'GlazeSetup.exe'))) { throw "GlazeSetup.exe not built in $window" }

# ── 3. launcher and packer ───────────────────────────────────────────────────
$cmakeBuild = Join-Path $work 'launcher'
Invoke-Checked 'cmake configure (launcher)' {
  cmake -S $launcher -B $cmakeBuild -A x64 "-DGLAZE_VERSION=$Version"
}
Invoke-Checked 'cmake build (launcher)' { cmake --build $cmakeBuild --config Release }
$launcherExe = Join-Path $cmakeBuild 'Release\GlazeSetup.exe'
$packExe = Join-Path $cmakeBuild 'Release\setup_pack.exe'

# ── 4. one file ──────────────────────────────────────────────────────────────
$setup = Join-Path $OutputDir "$BaseName.exe"
Invoke-Checked 'setup_pack' { & $packExe $launcherExe $window $zipPath $setup }

# The launcher is a window program, so Start-Process -Wait for its exit code.
$check = Join-Path $work 'selftest'
$p = Start-Process -FilePath $setup -ArgumentList @('--selftest', "`"$check`"") -Wait -PassThru
if ($p.ExitCode -ne 0 -or -not (Test-Path (Join-Path $check 'GlazeSetup.exe'))) {
  throw "The packed setup does not unpack (exit code $($p.ExitCode))"
}

$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
# `<hash>  <file>`, the format sha256sum -c reads. The in-app updater prefers
# the digest GitHub reports for the asset and falls back to this file.
[IO.File]::WriteAllText("$setup.sha256", "$hash  $BaseName.exe`n")
$mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host "Built $setup ($mb MB)"
Write-Output $setup
