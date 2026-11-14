#!/bin/sh
# Fable Code installer for macOS and Linux.
# One-line install (served from fable.fondation.ink once published):
#   curl -fsSL https://fable.fondation.ink/install.sh | bash
#
# What it does (nothing hidden):
#   1. Detects your OS (macOS/Linux) and CPU (x64/arm64), and on Linux
#      whether you use glibc or musl (Alpine).
#   2. Downloads the matching prebuilt Fable Code binary from the public
#      release in leonnett/fable-install — no source checkout, no build,
#      no git, no account needed.
#   3. Verifies the download's SHA-256 checksum against versions.json from
#      the same release, and refuses to install on any mismatch.
#   4. Installs it as `fable` (plus the compatibility alias `tera`) into
#      $HOME/.local/bin, then verifies it with `fable --version`.
#
# To install a different release, set FABLE_VERSION (e.g. v0.0.2).
# To update later, re-run this same command. To uninstall, delete
# $HOME/.local/bin/fable and $HOME/.local/bin/tera; your data in ~/.fable
# is kept unless you delete it yourself.
# Windows is NOT covered by this script: use install.ps1 instead.
# Strict mode, minus nounset: macOS ships bash 3.2, whose `set -u` reports
# variables assigned by command substitution as "unbound" (FILE at the
# download step on macOS arm64). The explicit [ -n ... ] || die checks
# below are the real validation and give a clear error instead.
set -e

VERSION="${FABLE_VERSION:-v0.0.2}"
REPO="leonnett/fable-install"
BIN_DIR="${FABLE_BIN_DIR:-$HOME/.local/bin}"
TMP_DIR="${TMPDIR:-/tmp}/fable-install-$$"

say() { printf '%s\n' "[fable] $*"; }
die() { printf '%s\n' "[fable] ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# --- platform ---------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Darwin) OS_NAME="macOS" ;;
  Linux)  OS_NAME="Linux" ;;
  *) die "Unsupported OS: $OS. This script covers macOS and Linux only. On Windows use install.ps1." ;;
esac
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ARCH_NAME="arm64" ;;
  x86_64|amd64)  ARCH_NAME="x64" ;;
  *) die "Unsupported CPU architecture: $ARCH" ;;
esac

# Linux libc: musl (Alpine and friends) needs its own binary.
LIBC=""
if [ "$OS" = "Linux" ]; then
  if [ "${FABLE_INSTALL_MUSL:-}" = "1" ]; then
    LIBC="-musl"
  elif ldd --version 2>&1 | grep -qi musl; then
    LIBC="-musl"
  elif ls /lib/ld-musl-* 1>/dev/null 2>&1; then
    LIBC="-musl"
  fi
fi

case "$OS" in
  Darwin) PLATFORM_KEY="darwin-$ARCH_NAME" ;;
  Linux)  PLATFORM_KEY="linux-$ARCH_NAME$LIBC" ;;
esac
say "Installing Fable Code $VERSION on $OS_NAME ($ARCH_NAME${LIBC:+, musl})."

# --- prerequisites ----------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required but was not found. Install curl, then re-run this installer."
if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
else
  die "A SHA-256 tool is required (sha256sum or shasum) but neither was found. Install coreutils (macOS: brew install coreutils), then re-run."
fi

# --- release metadata -------------------------------------------------------
# versions.json is the single source of truth for file names and checksums.
mkdir -p "$TMP_DIR"
VERSIONS_URL="https://raw.githubusercontent.com/$REPO/$VERSION/versions.json"
say "Fetching release metadata ($VERSIONS_URL)…"
curl -fsSL "$VERSIONS_URL" -o "$TMP_DIR/versions.json" || die "Could not download versions.json for $VERSION. Check your network connection."
ASSET_JSON=""
FILE=""
EXPECTED_SHA=""
ASSET_JSON="$(grep -o "\"$PLATFORM_KEY\":{[^}]*}" "$TMP_DIR/versions.json" || true)"
[ -n "$ASSET_JSON" ] || die "No binary listed for platform '$PLATFORM_KEY' in $VERSION. See https://github.com/$REPO/releases for supported platforms."
FILE="$(printf '%s' "$ASSET_JSON" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
EXPECTED_SHA="$(printf '%s' "$ASSET_JSON" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')"
[ -n "$FILE" ] && [ -n "$EXPECTED_SHA" ] || die "Could not read the file name or checksum for '$PLATFORM_KEY' from versions.json."

# --- download + verify ------------------------------------------------------
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$FILE"
say "Downloading $FILE…"
curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/$FILE" || die "Could not download $DOWNLOAD_URL. Check your network connection."
say "Verifying SHA-256 checksum…"
ACTUAL_SHA="$(cd "$TMP_DIR" && $SHA_CMD "$FILE" | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || die "Checksum mismatch for $FILE (expected $EXPECTED_SHA, got $ACTUAL_SHA). The download may be corrupted — delete it and re-run. Nothing was installed."

# --- install ----------------------------------------------------------------
mkdir -p "$BIN_DIR"
cp "$TMP_DIR/$FILE" "$BIN_DIR/fable"
chmod +x "$BIN_DIR/fable"
# Compatibility alias: the CLI was previously called Tera.
ln -sf fable "$BIN_DIR/tera"

# --- verify -----------------------------------------------------------------
say "Verifying the install…"
INSTALLED_VERSION="$("$BIN_DIR/fable" --version)"
say "fable --version: $INSTALLED_VERSION"
"$BIN_DIR/fable" --help >/dev/null || die "'fable --help' failed after install."
say "Installed Fable Code $INSTALLED_VERSION ($VERSION, $PLATFORM_KEY)."

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say "NOTE: $BIN_DIR is not on your PATH yet. Add it for this shell with:"
    say "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    say "Or add that line to ~/.zshrc (macOS) or ~/.bashrc (Linux) to keep it."
    ;;
esac

say "Next steps:"
say "  fable login     Sign in with your Fable account"
say "  fable --help    See all commands"
say "  Docs: https://www.fondation.ink/fable/docs/fable-code/install/"
say "Update later by re-running this same installer."
