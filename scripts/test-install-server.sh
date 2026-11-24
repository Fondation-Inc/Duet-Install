#!/bin/sh
# Lightweight end-to-end verification suite for install-server.sh and repo manifests.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/install-server.sh"
DESKTOP_MANIFEST="$REPO_ROOT/desktop-manifest.example.json"
CLI_VERSIONS="$REPO_ROOT/versions.json"

TMP_ROOT=""
HTTP_PID=""

cleanup() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
    HTTP_PID=""
  fi
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT INT TERM

fail() {
  printf '[test-install-server] FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[test-install-server] PASS: %s\n' "$*"
}

main() {
  [ -x "$INSTALLER" ] || fail "install-server.sh must be executable"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to run local mock HTTP tests"

  # 1. Shell syntax & lint checks
  sh -n "$INSTALLER" || fail "sh -n install-server.sh failed"
  bash -n "$INSTALLER" || fail "bash -n install-server.sh failed"
  pass "sh -n and bash -n syntax checks"

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s sh "$INSTALLER" || fail "shellcheck -s sh install-server.sh failed"
    shellcheck -s sh "$0" || fail "shellcheck -s sh scripts/test-install-server.sh failed"
    pass "shellcheck -s sh"
  fi

  # 2. Validate JSON files in repo
  python3 -m json.tool "$DESKTOP_MANIFEST" >/dev/null || fail "desktop-manifest.example.json is invalid JSON"
  python3 -m json.tool "$CLI_VERSIONS" >/dev/null || fail "versions.json is invalid JSON"
  python3 - "$DESKTOP_MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    doc = json.load(f)
required = {
    "Duet-0.0.1-arm64.dmg",
    "Duet-0.0.1-x64.dmg",
    "Duet-0.0.1-x64.exe",
    "Duet-0.0.1-x64.AppImage",
    "Duet-0.0.1-arm64.AppImage",
    "duet-mac.yml",
    "duet.yml",
    "duet-linux.yml",
    "SHA256SUMS.txt",
}
raw = json.dumps(doc)
missing = [name for name in sorted(required) if name not in raw]
if missing:
    raise SystemExit(f"Missing required desktop asset names: {missing}")
if doc.get("channel") != "duet" or doc.get("release") != "desktop-v0.0.1":
    raise SystemExit("Unexpected channel or release in desktop-manifest.example.json")
PY
  pass "JSON validation for desktop-manifest.example.json and versions.json"

  # 3. Create isolated /tmp workspace & mock HTTP server
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/duet-install-test-XXXXXX")"
  HOST_DIR="$TMP_ROOT/host"
  PAYLOAD_DIR="$TMP_ROOT/payload"
  mkdir -p "$HOST_DIR" "$PAYLOAD_DIR/bin"

  cat > "$PAYLOAD_DIR/bin/duet-server" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version|-v)
    printf 'duet-server 0.0.1\n'
    ;;
  --help|-h)
    printf 'Duet Server mock binary 0.0.1\n'
    ;;
  serve)
    exit 0
    ;;
  *)
    printf 'duet-server mock\n'
    ;;
esac
EOF
  chmod 0755 "$PAYLOAD_DIR/bin/duet-server"

  TAR_NAME="duet-server-0.0.1-linux.tar.gz"
  RAW_NAME="duet-server-0.0.1-linux-raw"
  SYMLINK_NAME="duet-server-0.0.1-linux-symlink.tar.gz"
  MALICIOUS_BIN="$HOST_DIR/malicious-server.sh"
  MALICIOUS_MARKER="$HOST_DIR/malicious-server-executed"
  tar -czf "$HOST_DIR/$TAR_NAME" -C "$PAYLOAD_DIR" .
  cp "$PAYLOAD_DIR/bin/duet-server" "$HOST_DIR/$RAW_NAME"

  cat > "$MALICIOUS_BIN" <<EOF
#!/bin/sh
printf 'unexpected execution\n' > '$MALICIOUS_MARKER'
if [ "\${1:-}" = "--version" ]; then
  printf 'duet-server 0.0.99\n'
  exit 0
fi
exit 0
EOF
  chmod 0755 "$MALICIOUS_BIN"
  python3 - "$HOST_DIR/$SYMLINK_NAME" "$MALICIOUS_BIN" <<'PY'
import sys, tarfile

archive, target = sys.argv[1:]
with tarfile.open(archive, "w:gz") as out:
    directory = tarfile.TarInfo("bin/")
    directory.type = tarfile.DIRTYPE
    directory.mode = 0o755
    out.addfile(directory)
    executable = tarfile.TarInfo("bin/duet-server")
    executable.type = tarfile.SYMTYPE
    executable.linkname = target
    out.addfile(executable)
PY

  PORT_FILE="$TMP_ROOT/http.port"
  ENROLL_LOG="$TMP_ROOT/enroll.log"

  python3 - "$HOST_DIR" "$PORT_FILE" "$ENROLL_LOG" <<'PY' &
import functools
import http.server
import json
import os
import sys

host_dir, port_file, enroll_log = sys.argv[1], sys.argv[2], sys.argv[3]

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        if self.path != "/enroll":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        auth = self.headers.get("Authorization", "")
        with open(enroll_log, "a", encoding="utf-8") as f:
            f.write(json.dumps({"auth": auth, "body": json.loads(body)}) + "\n")
        if auth != "Bearer test-secret-tok":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"unauthorized"}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"computerIndex":1,"maxComputers":5}')

handler_cls = functools.partial(Handler, directory=host_dir)
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
  HTTP_PID=$!

  _waited=0
  while [ ! -s "$PORT_FILE" ] && [ "$_waited" -lt 50 ]; do
    sleep 0.1
    _waited=$((_waited + 1))
  done
  [ -s "$PORT_FILE" ] || fail "Mock HTTP server failed to start"
  PORT="$(cat "$PORT_FILE")"

  # Build manifests with real SHA-256 digests
  python3 - "$HOST_DIR" "$TAR_NAME" "$RAW_NAME" "$SYMLINK_NAME" "$PORT" <<'PY'
import hashlib, json, os, sys

host_dir, tar_name, raw_name, symlink_name, port = sys.argv[1:]

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()

tar_sha = sha256_file(os.path.join(host_dir, tar_name))
tar_size = os.path.getsize(os.path.join(host_dir, tar_name))
raw_sha = sha256_file(os.path.join(host_dir, raw_name))
symlink_sha = sha256_file(os.path.join(host_dir, symlink_name))
symlink_size = os.path.getsize(os.path.join(host_dir, symlink_name))
bad_sha = ("0" if tar_sha[0] != "0" else "1") + tar_sha[1:]

plats = ["linux-x64", "linux-arm64", "linux-x64-musl", "linux-arm64-musl"]

manifest = {
    "version": "0.0.1",
    "release": "server-v0.0.1",
    "runtime": "bundled",
    "assets": {
        p: {
            "file": tar_name,
            "url": f"http://127.0.0.1:{port}/{tar_name}",
            "sha256": tar_sha,
            "size": tar_size,
        }
        for p in plats
    },
}

manifest_raw = {
    "version": "0.0.2",
    "release": "server-v0.0.2",
    "runtime": "bundled",
    "assets": {
        p: {
            "file": raw_name,
            "sha256": raw_sha,
        }
        for p in plats
    },
}

manifest_symlink = {
    "version": "0.0.1",
    "release": "server-v0.0.1",
    "runtime": "bundled",
    "assets": {
        p: {
            "file": symlink_name,
            "url": f"http://127.0.0.1:{port}/{symlink_name}",
            "sha256": symlink_sha,
            "size": symlink_size,
        }
        for p in plats
    },
}

manifest_bad_sha = {
    "version": "0.0.1",
    "release": "server-v0.0.1",
    "assets": {
        p: {
            "file": tar_name,
            "url": f"http://127.0.0.1:{port}/{tar_name}",
            "sha256": bad_sha,
        }
        for p in plats
    },
}

manifest_insecure = {
    "version": "0.0.1",
    "release": "server-v0.0.1",
    "assets": {
        p: {
            "file": tar_name,
            "url": f"http://example.com/{tar_name}",
            "sha256": tar_sha,
        }
        for p in plats
    },
}

for name, obj in [
    ("server-manifest.json", manifest),
    ("server-manifest-raw.json", manifest_raw),
    ("server-manifest-symlink.json", manifest_symlink),
    ("server-manifest-bad-sha.json", manifest_bad_sha),
    ("server-manifest-insecure.json", manifest_insecure),
]:
    with open(os.path.join(host_dir, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
PY

  # 4. Test 1: JSON mode end-to-end
  HOME1="$TMP_ROOT/home1"
  mkdir -p "$HOME1"
  JSON_OUT1="$TMP_ROOT/json1.out"
  JSON_ERR1="$TMP_ROOT/json1.err"
  env -i HOME="$HOME1" PATH="$PATH" SHELL="/bin/bash" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest.json" \
    sh "$INSTALLER" >"$JSON_OUT1" 2>"$JSON_ERR1" || fail "JSON mode install failed: $(cat "$JSON_OUT1" "$JSON_ERR1")"

  [ ! -s "$JSON_ERR1" ] || fail "Expected empty stderr in DUET_JSON=1 mode, got: $(cat "$JSON_ERR1")"
  python3 - "$JSON_OUT1" <<'PY'
import json, sys
events = []
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for idx, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        events.append(obj)
names = [e.get("event") for e in events]
for req in ["preflight", "download", "verify", "install", "enroll", "ready"]:
    if req not in names:
        raise SystemExit(f"Missing event {req!r} in {names}")
ready = [e for e in events if e.get("event") == "ready"][-1]
if ready.get("version") != "0.0.1" or ready.get("maxComputers") != 5 or ready.get("reusedExisting") is not False:
    raise SystemExit(f"Unexpected ready payload: {ready}")
PY
  [ -L "$HOME1/.local/bin/duet-server" ] || fail "Missing ~/.local/bin/duet-server symlink"
  [ -x "$HOME1/.duet/server/current/bin/duet-server" ] || fail "Missing installed duet-server binary"
  VER_OUT="$("$HOME1/.local/bin/duet-server" --version)"
  [ "$VER_OUT" = "duet-server 0.0.1" ] || fail "Unexpected duet-server --version output: $VER_OUT"
  [ -x "$HOME1/.duet/server/duet-server-supervisor.sh" ] || fail "Missing supervisor script"
  sh -n "$HOME1/.duet/server/duet-server-supervisor.sh" || fail "Generated supervisor script syntax invalid"
  pass "JSON mode (DUET_JSON=1) end-to-end install & NDJSON validation"

  # 5. Test 2: Idempotent re-run in human mode (preserves data/, no duplicate PATH lines)
  printf 'vault-sentinel\n' > "$HOME1/.duet/server/data/vault.db"
  HUMAN_OUT="$TMP_ROOT/human.out"
  env -i HOME="$HOME1" PATH="$PATH" SHELL="/bin/bash" \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest.json" \
    sh "$INSTALLER" >"$HUMAN_OUT" 2>&1 || fail "Human mode re-run failed: $(cat "$HUMAN_OUT")"
  grep -Fq "vault-sentinel" "$HOME1/.duet/server/data/vault.db" || fail "Data sentinel was corrupted on re-run"
  # shellcheck disable=SC2016
  PATH_COUNT="$(grep -Fxc 'export PATH="$HOME/.local/bin:$PATH"' "$HOME1/.bashrc")"
  [ "$PATH_COUNT" = "1" ] || fail "Expected exactly 1 PATH line in .bashrc, found $PATH_COUNT"

  # Second JSON re-run should report reusedExisting=true
  JSON_OUT2="$TMP_ROOT/json2.out"
  env -i HOME="$HOME1" PATH="$PATH" SHELL="/bin/bash" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest.json" \
    sh "$INSTALLER" >"$JSON_OUT2" || fail "Second JSON re-run failed"
  python3 - "$JSON_OUT2" <<'PY'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
ready = [e for e in events if e.get("event") == "ready"][-1]
if ready.get("reusedExisting") is not True:
    raise SystemExit(f"Expected reusedExisting=True on re-run, got {ready}")
PY
  pass "Human mode + idempotent re-run (data preserved, PATH deduplicated, reusedExisting=true)"

  # 6. Test 3: Piped bash execution with standalone raw binary (relative URL resolution)
  HOME_RAW="$TMP_ROOT/home_raw"
  mkdir -p "$HOME_RAW"
  JSON_RAW="$TMP_ROOT/json_raw.out"
  env -i HOME="$HOME_RAW" PATH="$PATH" SHELL="/bin/bash" \
    bash -s -- --json --manifest-url "http://127.0.0.1:$PORT/server-manifest-raw.json" < "$INSTALLER" \
    >"$JSON_RAW" || fail "Piped bash raw binary install failed"
  [ -x "$HOME_RAW/.local/bin/duet-server" ] || fail "Raw binary symlink missing"
  [ "$("$HOME_RAW/.local/bin/duet-server" --version)" = "duet-server 0.0.1" ] || fail "Raw binary execution check failed"
  pass "Piped bash install with raw standalone binary"

  # A bundle must not point its executable at an external host path.
  HOME_SYMLINK="$TMP_ROOT/home_symlink"
  mkdir -p "$HOME_SYMLINK"
  if env -i HOME="$HOME_SYMLINK" PATH="$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest-symlink.json" \
    sh "$INSTALLER" >"$TMP_ROOT/symlink.out" 2>&1; then
    fail "Archive with an external duet-server symlink unexpectedly succeeded"
  fi
  grep -Fq '"code":"INVALID_ARTIFACT"' "$TMP_ROOT/symlink.out" || fail "Expected INVALID_ARTIFACT for symlinked duet-server"
  [ ! -e "$MALICIOUS_MARKER" ] || fail "Installer executed the external symlink target during verification"
  [ ! -e "$HOME_SYMLINK/.duet/server/current" ] || fail "Symlinked executable was installed"
  pass "Archive symlink to an external duet-server is rejected before execution"

  # 7. Test 4: SHA-256 mismatch FAILS CLOSED (nothing installed)
  HOME_BAD="$TMP_ROOT/home_bad"
  mkdir -p "$HOME_BAD"
  JSON_BAD="$TMP_ROOT/json_bad.out"
  if env -i HOME="$HOME_BAD" PATH="$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest-bad-sha.json" \
    sh "$INSTALLER" >"$JSON_BAD" 2>&1; then
    fail "SHA-256 mismatch unexpectedly succeeded!"
  fi
  python3 - "$JSON_BAD" <<'PY'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
errs = [e for e in events if e.get("event") == "error"]
if not errs or errs[-1].get("code") != "CHECKSUM_MISMATCH":
    raise SystemExit(f"Expected CHECKSUM_MISMATCH error event, got: {events}")
PY
  [ ! -e "$HOME_BAD/.duet/server/current" ] || fail "Partial server dir created on checksum failure"
  [ ! -e "$HOME_BAD/.local/bin/duet-server" ] || fail "Symlink created on checksum failure"
  pass "SHA-256 mismatch fails closed (CHECKSUM_MISMATCH, nothing installed)"

  # 8. Test 5: Non-HTTPS remote URLs rejected (both manifest URL and artifact URL)
  HOME_INSEC="$TMP_ROOT/home_insec"
  mkdir -p "$HOME_INSEC"
  if env -i HOME="$HOME_INSEC" PATH="$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://example.com/server-manifest.json" \
    sh "$INSTALLER" >"$TMP_ROOT/insec1.out" 2>&1; then
    fail "Insecure manifest URL unexpectedly accepted"
  fi
  grep -Fq '"code":"INSECURE_URL"' "$TMP_ROOT/insec1.out" || fail "Expected INSECURE_URL for remote http manifest"

  if env -i HOME="$HOME_INSEC" PATH="$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest-insecure.json" \
    sh "$INSTALLER" >"$TMP_ROOT/insec2.out" 2>&1; then
    fail "Insecure artifact URL unexpectedly accepted"
  fi
  grep -Fq '"code":"INSECURE_URL"' "$TMP_ROOT/insec2.out" || fail "Expected INSECURE_URL for remote http artifact"
  pass "Strict HTTPS enforcement rejects non-loopback HTTP URLs"

  # 9. Test 6: Disk space check (DISK_FULL)
  if env -i HOME="$HOME_INSEC" PATH="$PATH" DUET_JSON=1 DUET_MIN_DISK_MB=999999999 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest.json" \
    sh "$INSTALLER" >"$TMP_ROOT/disk.out" 2>&1; then
    fail "DISK_FULL check unexpectedly succeeded"
  fi
  grep -Fq '"code":"DISK_FULL"' "$TMP_ROOT/disk.out" || fail "Expected DISK_FULL error event"
  pass "Disk space check fails clearly with DISK_FULL"

  # 10. Test 7: SSH permission hints + Enrollment endpoint without token leakage
  HOME_ENROLL="$TMP_ROOT/home_enroll"
  mkdir -p "$HOME_ENROLL/.ssh"
  chmod 0755 "$HOME_ENROLL/.ssh"
  printf 'ssh-ed25519 AAAA test@example\n' > "$HOME_ENROLL/.ssh/authorized_keys"
  chmod 0644 "$HOME_ENROLL/.ssh/authorized_keys"

  JSON_ENROLL="$TMP_ROOT/json_enroll.out"
  env -i HOME="$HOME_ENROLL" PATH="$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest.json" \
    sh "$INSTALLER" --enroll-token "test-secret-tok" --enroll-url "http://127.0.0.1:$PORT/enroll" \
    >"$JSON_ENROLL" || fail "Enrollment run failed: $(cat "$JSON_ENROLL")"

  if grep -Fq "test-secret-tok" "$JSON_ENROLL" "$HOME_ENROLL/.duet/server/install-state.json"; then
    fail "Enrollment token leaked into output or state file!"
  fi
  python3 - "$JSON_ENROLL" "$ENROLL_LOG" <<'PY'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
warnings = {e.get("code") for e in events if e.get("event") == "warning"}
if "SSH_DIR_PERMISSIONS" not in warnings or "SSH_AUTHORIZED_KEYS_PERMISSIONS" not in warnings:
    raise SystemExit(f"Missing SSH permission warnings: {warnings}")
ready = [e for e in events if e.get("event") == "ready"][-1]
if ready.get("enrolled") is not True or ready.get("enrollStatus") != "enrolled":
    raise SystemExit(f"Expected enrolled=True, got: {ready}")
with open(sys.argv[2], encoding="utf-8") as f:
    reqs = [json.loads(l) for l in f if l.strip()]
if not reqs or reqs[-1].get("auth") != "Bearer test-secret-tok":
    raise SystemExit(f"Enroll server did not receive expected auth header: {reqs}")
PY
  pass "SSH permission hints + enrollment flow (zero token leakage)"

  # 11. Test 8: --check-only preflight mode (zero downloads)
  CHECK_OUT="$TMP_ROOT/check_only.out"
  env -i HOME="$HOME_ENROLL" PATH="$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:9/unreachable.json" \
    sh "$INSTALLER" --check-only >"$CHECK_OUT" || fail "--check-only failed"
  python3 - "$CHECK_OUT" <<'PY'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
ready = [e for e in events if e.get("event") == "ready"][-1]
if ready.get("checkOnly") is not True:
    raise SystemExit(f"Expected checkOnly=True, got: {ready}")
PY
  pass "--check-only runs preflight without downloading"

  # 12. Test 9: runtime=node enforcement (fails cleanly when node missing/too old)
  cat > "$HOST_DIR/server-manifest-node.json" <<EOF
{
  "version": "0.0.1",
  "release": "server-v0.0.1",
  "runtime": "node",
  "minNodeVersion": "22.12.0",
  "assets": {
    "linux-x64": {"file": "$TAR_NAME", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"},
    "linux-arm64": {"file": "$TAR_NAME", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"},
    "linux-x64-musl": {"file": "$TAR_NAME", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"},
    "linux-arm64-musl": {"file": "$TAR_NAME", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}
  }
}
EOF
  FAKE_BIN="$TMP_ROOT/fake_bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/node" <<'EOF'
#!/bin/sh
printf 'v18.19.0\n'
EOF
  chmod 0755 "$FAKE_BIN/node"
  if env -i HOME="$HOME_INSEC" PATH="$FAKE_BIN:$PATH" DUET_JSON=1 \
    DUET_SERVER_MANIFEST_URL="http://127.0.0.1:$PORT/server-manifest-node.json" \
    sh "$INSTALLER" >"$TMP_ROOT/node_old.out" 2>&1; then
    fail "Old Node.js unexpectedly accepted for runtime=node"
  fi
  grep -Fq '"code":"NODE_VERSION_TOO_OLD"' "$TMP_ROOT/node_old.out" || fail "Expected NODE_VERSION_TOO_OLD error"
  pass "Node.js version check (NODE_VERSION_TOO_OLD)"

  printf '\n[test-install-server] ALL CHECKS PASSED\n'
}

main "$@"
