#!/bin/sh
# Fable Code installer for macOS and Linux.
# One-line install:
#   curl -fsSL https://fable.fondation.ink/install.sh | bash
#
# What it does (nothing hidden):
#   1. Detects your OS (macOS/Linux) and CPU (x64/arm64), and on Linux
#      whether you use glibc or musl (Alpine).
#   2. Downloads versions.json (the release manifest) for the release
#      and resolves the matching prebuilt Fable Code binary from the
#      public release in leonnett/fable-install — no source checkout,
#      no build, no git, no account needed.
#   3. Downloads the binary with a progress bar and prints its size.
#   4. Verifies the download's SHA-256 checksum against versions.json
#      from the same release, and refuses to install on any mismatch.
#   5. Installs it as `fable` (plus the compatibility alias `tera`) into
#      $HOME/.local/bin, adds that folder to your shell PATH if needed,
#      then verifies it with `fable --version`.
#
# To install a different release, set FABLE_VERSION (e.g. v0.0.5).
# To update later, re-run this same command. To uninstall, delete
# $HOME/.local/bin/fable and $HOME/.local/bin/tera; your data in ~/.fable
# is kept unless you delete it yourself.
# Windows is NOT covered by this script: use install.ps1 instead.
#
# Safety notes:
# - Strict mode, minus nounset: macOS ships bash 3.2, whose `set -u`
#   reports variables assigned by command substitution as "unbound"
#   (FILE at the download step on macOS arm64). The explicit
#   [ -n ... ] || die checks below are the real validation and give a
#   clear error instead.
# - Everything runs inside main(), called once at the end of the file.
#   When the script is piped to a shell (curl ... | bash), a truncated
#   download never reaches the `main` call, so nothing runs half-way.
set -e

VERSION="${FABLE_VERSION:-v0.0.5}"
REPO="leonnett/fable-install"
BIN_DIR="${FABLE_BIN_DIR:-$HOME/.local/bin}"
TMP_DIR="${TMPDIR:-/tmp}/fable-install-$$"

say() { printf '%s\n' "==> $*"; }
die() { printf '%s\n' "==> ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

main() {
  # --- platform -----------------------------------------------------------
  OS="$(uname -s)"
  case "$OS" in
    Darwin|Linux) ;;
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
  say "Detected target: $PLATFORM_KEY"

  # --- prerequisites ------------------------------------------------------
  command -v curl >/dev/null 2>&1 || die "curl is required but was not found. Install curl, then re-run this installer."
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
  else
    die "A SHA-256 tool is required (sha256sum or shasum) but neither was found. Install coreutils (macOS: brew install coreutils), then re-run."
  fi

  # --- release metadata ---------------------------------------------------
  # versions.json is the single source of truth for file names and checksums.
  mkdir -p "$TMP_DIR"
  VERSIONS_URL="https://raw.githubusercontent.com/$REPO/$VERSION/versions.json"
  if [ -n "${FABLE_VERSION:-}" ]; then
    say "Using version $VERSION from $VERSIONS_URL"
  else
    say "Resolving latest version from $VERSIONS_URL"
  fi
  curl -fsSL "$VERSIONS_URL" -o "$TMP_DIR/versions.json" || die "Could not download versions.json for $VERSION. Check your network connection."
  RESOLVED=""
  RESOLVED="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$TMP_DIR/versions.json" | head -n 1 || true)"
  if [ -n "${FABLE_VERSION:-}" ]; then
    say "Version: $VERSION"
  elif [ -n "$RESOLVED" ]; then
    say "Latest version: v$RESOLVED"
  else
    say "Latest version: $VERSION"
  fi
  ASSET_JSON=""
  FILE=""
  EXPECTED_SHA=""
  ASSET_JSON="$(grep -o "\"$PLATFORM_KEY\":{[^}]*}" "$TMP_DIR/versions.json" || true)"
  [ -n "$ASSET_JSON" ] || die "No binary listed for platform '$PLATFORM_KEY' in $VERSION. See https://github.com/$REPO/releases for supported platforms."
  FILE="$(printf '%s' "$ASSET_JSON" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
  EXPECTED_SHA="$(printf '%s' "$ASSET_JSON" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')"
  [ -n "$FILE" ] && [ -n "$EXPECTED_SHA" ] || die "Could not read the file name or checksum for '$PLATFORM_KEY' from versions.json."

  # --- download + verify --------------------------------------------------
  DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$FILE"
  say "Download $DOWNLOAD_URL"
  SIZE_BYTES=""
  SIZE_BYTES="$(curl -fsSLI "$DOWNLOAD_URL" 2>/dev/null | grep -i '^content-length:' | tail -n 1 | awk '{print $2}' | tr -d '\r' || true)"
  case "$SIZE_BYTES" in
    ''|*[!0-9]*) SIZE_BYTES="" ;;
  esac
  if [ -n "$SIZE_BYTES" ]; then
    SIZE_MIB="$(awk -v bytes="$SIZE_BYTES" 'BEGIN {printf "%.1f", bytes / 1048576}')"
    say "Download size: $SIZE_MIB MiB"
  else
    say "Download size: unknown"
  fi
  curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_DIR/$FILE" || die "Could not download $DOWNLOAD_URL. Check your network connection."
  say "Verifying checksum"
  ACTUAL_SHA="$(cd "$TMP_DIR" && $SHA_CMD "$FILE" | awk '{print $1}')"
  [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || die "Checksum mismatch for $FILE (expected $EXPECTED_SHA, got $ACTUAL_SHA). The download may be corrupted — delete it and re-run. Nothing was installed."

  # --- install ------------------------------------------------------------
  mkdir -p "$BIN_DIR"
  cp "$TMP_DIR/$FILE" "$BIN_DIR/fable"
  chmod +x "$BIN_DIR/fable"
  # Compatibility alias: the CLI was previously called Tera.
  ln -sf fable "$BIN_DIR/tera"
  say "Installed to $BIN_DIR/fable"

  # --- PATH ---------------------------------------------------------------
  # Add BIN_DIR to the shell startup file only when it is not already on
  # PATH and not already recorded there. Never touches the file otherwise.
  RC_FILE=""
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      case "${SHELL:-}" in
        *zsh) RC_FILE="$HOME/.zshrc" ;;
        *bash)
          if [ "$OS" = "Darwin" ]; then RC_FILE="$HOME/.bash_profile"; else RC_FILE="$HOME/.bashrc"; fi ;;
      esac
      if [ -z "$RC_FILE" ]; then
        if [ -f "$HOME/.zshrc" ]; then RC_FILE="$HOME/.zshrc";
        elif [ -f "$HOME/.bashrc" ]; then RC_FILE="$HOME/.bashrc";
        elif [ -f "$HOME/.bash_profile" ]; then RC_FILE="$HOME/.bash_profile"; fi
      fi
      if [ -n "$RC_FILE" ]; then
        if [ "$BIN_DIR" = "$HOME/.local/bin" ]; then
          PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
        else
          PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""
        fi
        if grep -Fqx "$PATH_LINE" "$RC_FILE" 2>/dev/null; then
          say "$BIN_DIR is already in $RC_FILE."
        elif printf '%s\n' "$PATH_LINE" >> "$RC_FILE" 2>/dev/null; then
          say "Added $BIN_DIR to PATH in $RC_FILE"
        else
          say "Could not update $RC_FILE. Add this line yourself: $PATH_LINE"
        fi
      else
        say "Could not detect your shell startup file. Add $BIN_DIR to your PATH to use fable from any directory."
      fi
      ;;
  esac

  # --- verify -------------------------------------------------------------
  say "Verifying install"
  INSTALLED_VERSION="$("$BIN_DIR/fable" --version 2>/dev/null)" || die "'fable --version' failed after install."
  "$BIN_DIR/fable" --help >/dev/null 2>&1 || die "'fable --help' failed after install."
  say "Installed fable $INSTALLED_VERSION ($VERSION, $PLATFORM_KEY)."

  say "Done. Run: fable --version"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      if [ -n "$RC_FILE" ]; then
        say "If 'fable' is not found, restart your shell or run: source $RC_FILE"
      else
        say "If 'fable' is not found, restart your shell or add $BIN_DIR to your PATH."
      fi
      ;;
  esac
}

main "$@"
