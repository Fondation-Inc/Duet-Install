# Fable Code installer for Windows (PowerShell).
#
# One-line install (run in Windows PowerShell, not as Administrator):
#   irm https://fable.fondation.ink/install.ps1 | iex
#
# STATUS: NOT TESTED — written from the macOS/Linux installer, but never
# executed on Windows (no Windows machine was available in this
# environment). Do not present the Windows path as verified until someone
# runs it on real Windows and confirms `fable --version` prints a version.
#
# What it does:
#   1. Detects your CPU (x64/arm64).
#   2. Downloads the matching prebuilt Fable Code binary from the public
#      release in leonnett/fable-install — no source checkout, no build,
#      no git, no account needed.
#   3. Verifies the download's SHA-256 checksum against versions.json from
#      the same release, and refuses to install on any mismatch.
#   4. Installs it as fable.exe (plus the compatibility alias tera.exe)
#      into $env:LOCALAPPDATA\FableCode\bin, adds that folder to your user
#      PATH, then verifies with `fable --version`.
#
# To install a different release, set $env:FABLE_VERSION (e.g. v0.0.4).
# To update later, re-run this same command. To uninstall, delete
# fable.exe and tera.exe from the bin folder; your data in %USERPROFILE%\.fable
# is kept unless you delete it yourself.
# Requires Windows 10 version 1809 or later.
# If Windows gives trouble, WSL2 + the Unix installer is the fallback.
$ErrorActionPreference = "Stop"

function Say($msg) { Write-Host "[fable] $msg" }
function Die($msg) { throw "[fable] ERROR: $msg" }

$version = if ($env:FABLE_VERSION) { $env:FABLE_VERSION } else { "v0.0.4" }
$repo = "leonnett/fable-install"
$binDir = if ($env:FABLE_BIN_DIR) { $env:FABLE_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "FableCode\bin" }

# --- platform ---------------------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -eq "ARM64") { $platformKey = "windows-arm64" }
elseif ($arch -eq "AMD64") { $platformKey = "windows-x64" }
else { Die "Unsupported CPU architecture: $arch" }
Say "Installing Fable Code $version on Windows ($platformKey)."

# --- release metadata -------------------------------------------------------
# versions.json is the single source of truth for file names and checksums.
$versionsUrl = "https://raw.githubusercontent.com/$repo/$version/versions.json"
Say "Fetching release metadata ($versionsUrl)…"
try {
  $versions = Invoke-RestMethod -Uri $versionsUrl
} catch {
  Die "Could not download versions.json for $version. Check your network connection."
}
$asset = $versions.assets.$platformKey
if (-not $asset) { Die "No binary listed for platform '$platformKey' in $version. See https://github.com/$repo/releases for supported platforms." }
$file = $asset.file
$expectedSha = $asset.sha256
if (-not $file -or -not $expectedSha) { Die "Could not read the file name or checksum for '$platformKey' from versions.json." }

# --- download + verify ------------------------------------------------------
$tmpDir = Join-Path $env:TEMP ("fable-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  $downloadUrl = "https://github.com/$repo/releases/download/$version/$file"
  $tmpFile = Join-Path $tmpDir $file
  Say "Downloading $file…"
  Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpFile
  Say "Verifying SHA-256 checksum…"
  $actualSha = (Get-FileHash -Algorithm SHA256 -Path $tmpFile).Hash.ToLower()
  if ($actualSha -ne $expectedSha.ToLower()) {
    Die "Checksum mismatch for $file (expected $expectedSha, got $actualSha). The download may be corrupted — delete it and re-run. Nothing was installed."
  }

  # --- install --------------------------------------------------------------
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  Copy-Item -Path $tmpFile -Destination (Join-Path $binDir "fable.exe") -Force
  # Compatibility alias: the CLI was previously called Tera.
  Copy-Item -Path $tmpFile -Destination (Join-Path $binDir "tera.exe") -Force
} finally {
  Remove-Item -Recurse -Force -Path $tmpDir -ErrorAction SilentlyContinue
}

# --- user PATH ---------------------------------------------------------------
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$binDir*") {
  [System.Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
  Say "Added $binDir to your user PATH. Open a NEW terminal window to use it."
} else {
  Say "$binDir is already on your user PATH."
}
$env:Path = "$binDir;" + $env:Path

# --- verify -----------------------------------------------------------------
Say "Verifying the install…"
$installedVersion = & (Join-Path $binDir "fable.exe") --version
Say "fable --version: $installedVersion"
& (Join-Path $binDir "fable.exe") --help | Out-Null
if ($LASTEXITCODE -ne 0) { Die "'fable --help' failed after install." }
Say "Installed Fable Code $installedVersion ($version, $platformKey)."
Say "Next steps:"
Say "  fable login     Sign in with your Fable account"
Say "  fable --help    See all commands"
Say "  Docs: https://www.fondation.ink/fable/docs/fable-code/install/"
Say "Update later by re-running this same installer."
Say "NOTE: this Windows installer has NOT been tested on Windows yet."
