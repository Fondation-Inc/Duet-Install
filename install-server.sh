#!/bin/sh
# Duet server setup: links a Linux server to the Duet app through the Duet link service.
#
#   curl -fsSL https://duet.lat/install-server.sh | sh -s -- <code> [--cloudflare|--tailscale|--ssh|--relay]
#
# <code> is the setup code the Duet app shows under "Add your own server" (7 characters), or the
# app's long install token. The server build is private: the link service hands it only to the setup
# session that code names, so there is nothing to install without one.
# Env: DUET_LINK_BASE (default https://link.dusk.bot, the link service the Duet app uses).
set -eu

LINK_BASE="${DUET_LINK_BASE:-https://link.dusk.bot}"
LINK_BASE="${LINK_BASE%/}"

say() { printf '%s\n' "$*" >&2; }
fail() { say "duet: $*"; exit 1; }

usage() {
  say "Usage: curl -fsSL https://duet.lat/install-server.sh | sh -s -- <code> [--cloudflare|--tailscale|--ssh|--relay]"
  say ""
  say "Get <code> in the Duet app: Add your own server. The app shows the code and the full line to paste."
}

case "$LINK_BASE" in
  https://*) PROTO="=https" ;;
  http://127.0.0.1 | http://127.0.0.1:* | http://localhost | http://localhost:*) PROTO="=http,https" ;;
  *) fail "DUET_LINK_BASE must be an https:// address." ;;
esac

CODE="" WAY=""
for arg in "$@"; do
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    --cloudflare | --tailscale | --ssh | --relay)
      [ -z "$WAY" ] || fail "choose only one of --cloudflare, --tailscale, --ssh, --relay."
      WAY="${arg#--}" ;;
    -*) usage; fail "unknown option: $arg" ;;
    *)
      [ -z "$CODE" ] || fail "pass one setup code."
      CODE="$arg" ;;
  esac
done

if [ -z "$CODE" ]; then
  usage
  exit 1
fi

if printf '%s' "$CODE" | grep -Eq '^[abcdefghijkmnpqrstuvwxyz23456789]{7}$'; then
  URL="$LINK_BASE/s/$CODE${WAY:+/$WAY}"
  set --
elif printf '%s' "$CODE" | grep -Eq '^[a-z2-7-]{37}$'; then
  URL="$LINK_BASE/i/$CODE"
  if [ -n "$WAY" ]; then set -- "--$WAY"; else set --; fi
else
  fail "that is not a Duet setup code. Copy it again from the Duet app (Add your own server)."
fi

command -v curl >/dev/null 2>&1 || fail "curl is needed. Install it (for example: apt-get install -y curl ca-certificates) and run the line again."

TMP="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/duet-server.XXXXXXXX")" || fail "could not make a private temporary folder."
trap 'rm -rf "$TMP"' EXIT
SCRIPT="$TMP/setup.sh"

# Every other try over IPv4: some fresh servers have broken IPv6.
got=""
for family in "" -4 "" -4 ""; do
  # shellcheck disable=SC2086
  if curl -fsSL $family --proto "$PROTO" --proto-redir "$PROTO" -m 60 -o "$SCRIPT" "$URL" 2>"$TMP/err"; then
    got=1
    break
  fi
  if grep -q 'returned error: 4[0-9][0-9]' "$TMP/err" 2>/dev/null; then
    fail "the link service did not accept that code. Codes work only while the Duet app is waiting for this server; make a new one in the app and paste the line again."
  fi
  sleep 2
done
[ -n "$got" ] || fail "could not reach $LINK_BASE. Check this server's internet connection and paste the line again."
head -n 1 "$SCRIPT" | grep -q '^#!' || fail "the link service sent something that is not a setup script."

sh "$SCRIPT" "$@"
