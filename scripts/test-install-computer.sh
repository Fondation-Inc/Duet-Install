#!/bin/sh
set -eu
[ "$(uname -s)" = Linux ] && [ "$(id -u)" != 0 ] || exit 77
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export fixture
mkdir "$fixture/tools" "$fixture/home"
real_curl=$(command -v curl)
export real_curl
cat > "$fixture/tools/curl" <<'EOF'
#!/bin/sh
case "${2:-}" in
  https://raw.githubusercontent.com/*/versions.json) cp "$fixture/versions.json" "$4" ;;
  https://github.com/*/fixture-binary) cp "$fixture/binary" "$4" ;;
  *) exec "$real_curl" "$@" ;;
esac
EOF
cat > "$fixture/binary" <<'EOF'
#!/bin/sh
case "$*" in
  'computer prepare') touch "$HOME/prepare-called" ;;
  '--version'|'--help') exit 0 ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$fixture/tools/bwrap"
chmod +x "$fixture/tools/bwrap"
chmod +x "$fixture/tools/curl"
sha=$(sha256sum "$fixture/binary" | cut -d ' ' -f1)
case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) exit 77 ;; esac
printf '{"linux-%s":{"file":"fixture-binary","sha256":"%s"},"linux-%s-musl":{"file":"fixture-binary","sha256":"%s"}}\n' "$arch" "$sha" "$arch" "$sha" > "$fixture/versions.json"
export HOME="$fixture/home" PATH="$fixture/tools:$PATH" DUET_BIN_DIR="$fixture/home/.local/bin"
sh "$root/install.sh"
test ! -e "$HOME/prepare-called"
sh "$root/install.sh" --with-computer
test -f "$HOME/prepare-called"
echo "PASS: verified installer runs Computer setup only when requested."
