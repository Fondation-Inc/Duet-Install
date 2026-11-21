#!/bin/sh
# Tests install-server.sh against a local stand-in for the link service.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/install-server.sh"
WORK="$(mktemp -d)"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
pass() { printf '[test-install-server] PASS: %s\n' "$*"; }
die() { printf '[test-install-server] FAIL: %s\n' "$*" >&2; exit 1; }

sh -n "$SCRIPT"
bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh "$SCRIPT" "$0"; pass "shellcheck"; fi

mkdir -p "$WORK/www/s/abc2345" "$WORK/www/i"
printf '#!/bin/sh\necho "short-ok $*" > "%s/ran"\n' "$WORK" > "$WORK/www/s/abc2345/index.html"
mkdir -p "$WORK/www/s/abc2345/ssh"
printf '#!/bin/sh\necho "short-ssh $*" > "%s/ran"\n' "$WORK" > "$WORK/www/s/abc2345/ssh/index.html"
TOKEN="abcdefghijklmnopqrstuvwxyz234567-abcd"
printf '#!/bin/sh\necho "long $*" > "%s/ran"\n' "$WORK" > "$WORK/www/i/$TOKEN"
PORT=$((20000 + $$ % 20000))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SERVER_PID=$!
i=0; until curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 50 ] || die "mock server"; sleep 0.1; done
export DUET_LINK_BASE="http://127.0.0.1:$PORT"

sh "$SCRIPT" abc2345 && [ "$(cat "$WORK/ran")" = "short-ok " ] || die "short code"
pass "short code runs the link service script"
sh "$SCRIPT" abc2345 --ssh && [ "$(cat "$WORK/ran")" = "short-ssh " ] || die "short code with way"
pass "way goes in the short url"
sh "$SCRIPT" "$TOKEN" --relay && [ "$(cat "$WORK/ran")" = "long --relay" ] || die "long token"
pass "long token passes the way as an option"

if sh "$SCRIPT" 2>"$WORK/out"; then die "no code should fail"; fi
grep -q 'Add your own server' "$WORK/out" || die "no-code help"
pass "no code explains where to get one"
if sh "$SCRIPT" 'bad;code' 2>/dev/null; then die "bad code accepted"; fi
pass "malformed code refused"
if sh "$SCRIPT" zzz2345 2>"$WORK/out"; then die "unknown code should fail"; fi
grep -q 'did not accept that code' "$WORK/out" || die "unknown-code message"
pass "unknown code reports the link service refusal"
if DUET_LINK_BASE=http://example.com sh "$SCRIPT" abc2345 2>/dev/null; then die "plain http accepted"; fi
pass "non-loopback http refused"
printf '\n[test-install-server] ALL CHECKS PASSED\n'
