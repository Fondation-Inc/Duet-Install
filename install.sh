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
#   3. Downloads the binary.
#   4. Verifies the download's SHA-256 checksum against versions.json
#      from the same release, and refuses to install on any mismatch.
#   5. Installs it as `fable` (plus the compatibility alias `tera`) into
#      $HOME/.local/bin, adds that folder to your shell PATH if needed,
#      then verifies it with `fable --version`.
#
# What you see is deliberately little: a short header, a quiet
# "Installing…" while it works, and one line when it is done. Every check
# above still happens — it just stays silent unless something fails, in
# which case you get one short, plain message and nothing is installed.
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

VERSION="${FABLE_VERSION:-v0.0.7}"
REPO="leonnett/fable-install"
BIN_DIR="${FABLE_BIN_DIR:-$HOME/.local/bin}"
TMP_DIR="${TMPDIR:-/tmp}/fable-install-$$"
SPINNER_PID=""

say() { printf '%s\n' "$*"; }

# --- spinner ---------------------------------------------------------------
# On a real terminal, "Installing…" gets a small animated spinner on the
# same line. Anywhere else (piped output, CI, logs) it stays one plain
# line. The spinner never reads stdin and is always stopped before any
# other output, so it can never garble the result.
spinner_loop() {
  trap - EXIT
  while :; do
    for c in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
      printf '\rInstalling… %s ' "$c"
      sleep 0.1
    done
  done
}

start_spinner() {
  if [ -t 1 ]; then
    spinner_loop &
    SPINNER_PID=$!
  else
    say "Installing…"
  fi
}

stop_spinner() {
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r\033[K'
  fi
}

# Errors stay short and plain: no addresses, no technical details.
die() {
  stop_spinner
  printf '%s\n' "$*" >&2
  exit 1
}

cleanup() { stop_spinner; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

main() {
  say "Fable Code"
  say "──────────"
  start_spinner

  # --- platform -----------------------------------------------------------
  OS="$(uname -s)"
  case "$OS" in
    Darwin|Linux) ;;
    *) die "Sorry, this installer is for macOS and Linux. On Windows, use install.ps1." ;;
  esac
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64|aarch64) ARCH_NAME="arm64" ;;
    x86_64|amd64)  ARCH_NAME="x64" ;;
    *) die "Sorry, this computer's processor isn't supported yet." ;;
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

  # --- prerequisites ------------------------------------------------------
  command -v curl >/dev/null 2>&1 || die "curl is needed to install Fable Code. Install curl, then try again."
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
  else
    die "Your system is missing the tool that verifies downloads. Install coreutils (macOS: brew install coreutils), then try again."
  fi

  # --- release metadata ---------------------------------------------------
  # versions.json is the single source of truth for file names and checksums.
  mkdir -p "$TMP_DIR" 2>/dev/null || die "Something went wrong. Please try again."
  VERSIONS_URL="https://raw.githubusercontent.com/$REPO/$VERSION/versions.json"
  curl -fsSL "$VERSIONS_URL" -o "$TMP_DIR/versions.json" 2>/dev/null || die "Sorry, the download didn't work. Check your connection and try again."
  ASSET_JSON=""
  ASSET_JSON="$(grep -o "\"$PLATFORM_KEY\":{[^}]*}" "$TMP_DIR/versions.json" || true)"
  [ -n "$ASSET_JSON" ] || die "Sorry, there's no download for this computer yet."
  FILE=""
  EXPECTED_SHA=""
  FILE="$(printf '%s' "$ASSET_JSON" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
  EXPECTED_SHA="$(printf '%s' "$ASSET_JSON" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')"
  [ -n "$FILE" ] && [ -n "$EXPECTED_SHA" ] || die "Sorry, the download didn't work. Check your connection and try again."

  # --- download + verify --------------------------------------------------
  DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$FILE"
  curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/$FILE" 2>/dev/null || die "Sorry, the download didn't work. Check your connection and try again."
  ACTUAL_SHA="$(cd "$TMP_DIR" && $SHA_CMD "$FILE" | awk '{print $1}')"
  [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || die "Sorry, the download could not be verified. Nothing was installed. Please try again."

  # --- install ------------------------------------------------------------
  mkdir -p "$BIN_DIR" 2>/dev/null || die "Something went wrong. Please try again."
  cp "$TMP_DIR/$FILE" "$BIN_DIR/fable" 2>/dev/null || die "Something went wrong. Please try again."
  chmod +x "$BIN_DIR/fable" 2>/dev/null || die "Something went wrong. Please try again."
  # Compatibility alias: the CLI was previously called Tera.
  ln -sf fable "$BIN_DIR/tera" 2>/dev/null || true

  # --- PATH ---------------------------------------------------------------
  # Add BIN_DIR to the shell startup file only when it is not already on
  # PATH and not already recorded there. Never touches the file otherwise.
  # Silent: the only visible trace is one extra line at the end, and only
  # when the user has to do something (restart, or add it by hand).
  PATH_NOTE=""
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      RC_FILE=""
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
          PATH_NOTE="restart"
        elif printf '%s\n' "$PATH_LINE" >> "$RC_FILE" 2>/dev/null; then
          PATH_NOTE="restart"
        else
          PATH_NOTE="manual"
        fi
      else
        PATH_NOTE="manual"
      fi
      ;;
  esac

  # --- verify -------------------------------------------------------------
  "$BIN_DIR/fable" --version >/dev/null 2>&1 || die "Something went wrong after installing. Please try again."
  "$BIN_DIR/fable" --help >/dev/null 2>&1 || die "Something went wrong after installing. Please try again."

  # --- done ---------------------------------------------------------------
  stop_spinner
  if [ "$PATH_NOTE" = "restart" ]; then
    say "✓ Installed"
    say "Restart your terminal, then run \`fable\`."
  elif [ "$PATH_NOTE" = "manual" ]; then
    say "✓ Installed"
    say "Add $BIN_DIR to your PATH, then run \`fable\`."
  else
    say "✓ Installed — run \`fable\`"
  fi
  say "Need help? Run \`fable help\` or visit fable.fondation.ink"
}

main "$@"
