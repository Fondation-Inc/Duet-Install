# Duet installer for Windows (PowerShell).
#
# One-line install (run in Windows PowerShell, not as Administrator):
#   irm https://duet.lat/install.ps1 | iex
#
# STATUS: NOT TESTED - written from the macOS/Linux installer, but never
# executed on Windows (no Windows machine was available in this
# environment). Do not present the Windows path as verified until someone
# runs it on real Windows and confirms `duet --version` prints a version.
#
# What it does:
#   1. Detects your CPU (x64/arm64).
#   2. Downloads the matching prebuilt Duet binary from the public
#      release in Fondation-Inc/Duet-Install - no source checkout, no build,
#      no git, no account needed.
#   3. Verifies the download's SHA-256 checksum against versions.json from
#      the same release, and refuses to install on any mismatch.
#   4. Installs it as duet.exe (plus the compatibility aliases fable.exe
#      and tera.exe) into $env:LOCALAPPDATA\FableCode\bin, adds that
#      folder to your user PATH, then verifies with `duet --version`.
#
# To install a different release, set $env:DUET_VERSION (e.g. v0.1.0).
# $env:FABLE_VERSION still works as a fallback.
# To update later, re-run this same command. To uninstall, delete
# duet.exe, fable.exe and tera.exe from the bin folder; your data in
# %USERPROFILE%\.duet is kept unless you delete it yourself.
# Requires Windows 10 version 1809 or later.
# If Windows gives trouble, WSL2 + the Unix installer is the fallback.
$ErrorActionPreference = "Stop"
$stagedFile = $null
$tmpFile = $null

function Say($msg) { Write-Host "[duet] $msg" }
function Die($msg) { throw "[duet] ERROR: $msg" }

$version = if ($env:DUET_VERSION) { $env:DUET_VERSION } elseif ($env:FABLE_VERSION) { $env:FABLE_VERSION } else { $null }
$repo = "Fondation-Inc/Duet-Install"
if ($PSVersionTable.PSVersion.Major -le 5) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
if (-not $version) {
  try {
    $latest = & {
      $ProgressPreference = 'SilentlyContinue'
      Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/releases/latest" -TimeoutSec 30
    }
    $latestUrl = if ($latest.BaseResponse.ResponseUri) { $latest.BaseResponse.ResponseUri.AbsoluteUri } else { $latest.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
    if ($latestUrl -notmatch '/releases/tag/([^/]+)$') { throw "No release tag in redirect" }
    $version = $Matches[1]
  } catch { $version = "v0.1.0" }
}
# The folder name FableCode is kept on purpose: existing installs already
# have it on their user PATH, and moving it would break their updates.
$binDir = if ($env:DUET_BIN_DIR) { $env:DUET_BIN_DIR } elseif ($env:FABLE_BIN_DIR) { $env:FABLE_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "FableCode\bin" }

# --- platform ---------------------------------------------------------------
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }
if ($arch -eq "ARM64") { $platformKey = "windows-arm64" }
elseif ($arch -eq "AMD64" -or $arch -eq "X64") { $platformKey = "windows-x64" }
else { Die "Unsupported CPU architecture: $arch" }
Say "Installing Duet $version on Windows ($platformKey)."

# --- release metadata -------------------------------------------------------
# versions.json is the single source of truth for file names and checksums.
$versionsUrl = "https://raw.githubusercontent.com/$repo/$version/versions.json"
Say "Fetching release metadata ($versionsUrl)..."
try {
  $versions = & {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-RestMethod -Uri $versionsUrl
  }
} catch {
  Die "Could not download versions.json for $version. Check your network connection."
}
$asset = $versions.assets.$platformKey
if (-not $asset) { Die "No binary listed for platform '$platformKey' in $version. See https://github.com/$repo/releases for supported platforms." }
$file = $asset.file
$expectedSha = $asset.sha256
if (-not $file -or -not $expectedSha) { Die "Could not read the file name or checksum for '$platformKey' from versions.json." }

# --- download + verify ------------------------------------------------------
$tmpDir = Join-Path $env:TEMP ("duet-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  $downloadUrl = "https://github.com/$repo/releases/download/$version/$file"
  $tmpFile = Join-Path $tmpDir $file
  Say "Downloading $file..."
  & {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $tmpFile -TimeoutSec 300
  }
  Say "Verifying SHA-256 checksum..."
  $actualSha = (Get-FileHash -Algorithm SHA256 -Path $tmpFile).Hash.ToLower()
  if ($actualSha -ne $expectedSha.ToLower()) {
    Die "Checksum mismatch for $file (expected $expectedSha, got $actualSha). The download may be corrupted - delete it and re-run. Nothing was installed."
  }

  # --- install --------------------------------------------------------------
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $binDir = (Get-Item -LiteralPath $binDir).FullName
  $stagedFile = Join-Path $binDir (".duet-" + [Guid]::NewGuid().ToString("N") + ".exe")
  Copy-Item -LiteralPath $tmpFile -Destination $stagedFile
  $installedVersion = & $stagedFile --version
  if ($LASTEXITCODE -ne 0) { Die "'duet --version' failed before install. The previous binary was kept." }
  & $stagedFile --help | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "'duet --help' failed before install. The previous binary was kept." }
  $installedFile = Join-Path $binDir "duet.exe"
  if (Test-Path -LiteralPath $installedFile) {
    [System.IO.File]::Replace($stagedFile, $installedFile, [NullString]::Value)
  } else {
    [System.IO.File]::Move($stagedFile, $installedFile)
  }
  # Compatibility aliases: the CLI was previously called Fable Code
  # (command `fable`), and before that Tera (command `tera`). Both keep
  # working as copies of `duet` so existing scripts and muscle memory
  # do not break.
  Copy-Item -Path $tmpFile -Destination (Join-Path $binDir "fable.exe") -Force
  Copy-Item -Path $tmpFile -Destination (Join-Path $binDir "tera.exe") -Force
} finally {
  if ($stagedFile -and (Test-Path -LiteralPath $stagedFile)) { Remove-Item -LiteralPath $stagedFile -Force -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force -Path $tmpDir -ErrorAction SilentlyContinue
}

# --- user PATH ---------------------------------------------------------------
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if (@($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $binDir.TrimEnd('\')) {
  [System.Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
  Say "Added $binDir to your user PATH. Open a NEW terminal window to use it."
} else {
  Say "$binDir is already on your user PATH."
}
$env:Path = "$binDir;" + $env:Path

# --- verify -----------------------------------------------------------------
Say "Verifying the install..."
$installedVersion = & (Join-Path $binDir "duet.exe") --version
if ($LASTEXITCODE -ne 0) { Die "'duet --version' failed after install." }
Say "duet --version: $installedVersion"
& (Join-Path $binDir "duet.exe") --help | Out-Null
if ($LASTEXITCODE -ne 0) { Die "'duet --help' failed after install." }
Say "Installed Duet $installedVersion ($version, $platformKey)."
Say "Installed at $installedFile"
Say "Next steps:"
Say "  duet login      Sign in with your Fable account"
Say "  duet --help     See all commands"
Say "  Docs: https://www.fondation.ink/fable/docs/fable-code/install/"
Say "Update later by re-running this same installer."
Say "NOTE: this Windows installer has NOT been tested on Windows yet."
