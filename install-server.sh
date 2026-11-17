#!/bin/sh
# Duet Server bootstrap installer for Linux hosts.
#
# One-line bootstrap (interactive terminal or non-interactive SSH):
#   curl -fsSL https://duet.lat/install-server.sh | bash
#
# Structured JSON progress mode (for Duet Desktop "Add your own server" SSH flow):
#   curl -fsSL https://duet.lat/install-server.sh | DUET_JSON=1 bash
#
# Environment variables (all optional):
#   DUET_JSON=1                 Emit single-line NDJSON progress/error events on stdout.
#   DUET_SERVER_VERSION=...     Release tag or version to install (default: server-v0.0.1).
#   DUET_SERVER_MANIFEST_URL=.. Override manifest JSON URL (HTTPS required; loopback HTTP allowed for local tests).
#   DUET_SERVER_REPO=...        GitHub owner/repo for releases (default: leonnett/duet-install).
#   DUET_SERVER_DIR=...         Install directory (default: $HOME/.duet/server).
#   DUET_BIN_DIR=...            User bin directory for duet-server symlink (default: $HOME/.local/bin).
#   DUET_ENROLL_TOKEN=...       Optional enrollment token (never written to logs or stdout).
#   DUET_ENROLL_URL=...         Optional enrollment API endpoint (HTTPS required; loopback HTTP allowed for local tests).
#   DUET_MIN_DISK_MB=...        Minimum free disk space in MB (default: 500).
#   DUET_NO_PATH=1              Skip shell rc PATH modification.
#   DUET_NO_START=1             Do not start/restart the background service after installing.
#   DUET_START_SERVICE=1        Start the background service immediately (container/nohup or systemd).
#   DUET_INSTALL_MUSL=1         Force musl target selection (linux-<arch>-musl).
#
# Safety notes:
# - Strict POSIX sh with `set -e` and explicit validation before every use.
# - Everything runs inside main(), invoked once at the very end of the file so a
#   truncated piped download (`curl ... | bash`) never executes partially.
set -e

DEFAULT_REPO="leonnett/duet-install"
DEFAULT_VERSION="server-v0.0.1"
DEFAULT_MIN_DISK_MB="500"
DEFAULT_MIN_NODE_VERSION="22.12.0"

DUET_JSON_ENABLED="0"
TMP_DIR=""
MANIFEST_IS_LOCAL_HTTP="0"

# Preflight / state fields
OS_NAME=""
ARCH_NAME=""
LIBC_NAME=""
PLATFORM_KEY=""
DISTRO_ID=""
DISTRO_LIKE=""
DOWNLOADER=""
CURL_SUPPORTS_PROTO="0"
WGET_SUPPORTS_HTTPS_ONLY="0"
SHA_TOOL=""
HAS_TAR="0"
HAS_UNZIP="0"
HAS_GZIP="0"
NODE_VERSION=""
DISK_FREE_MB="0"
DISK_CHECK_PATH=""
SSH_DIR_PRESENT="false"
SSH_DIR_MODE=""
SSH_AK_MODE=""
SSH_WARN_DIR=""
SSH_WARN_AK=""
SERVICE_MODE=""
SERVICE_FILE=""
SUPERVISOR_SCRIPT=""
SERVER_DIR=""
BIN_DIR=""
EXISTING_VERSION=""
PATH_UPDATED="false"
RC_FILE_USED=""
ENROLLED="false"
ENROLL_STATUS="skipped"

json_escape() {
  JSON_VAL="$1" awk 'BEGIN {
    s = ENVIRON["JSON_VAL"]
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\r/, "\\r", s)
    gsub(/\n/, "\\n", s)
    gsub(/\t/, "\\t", s)
    gsub(/[\001-\037]/, "", s)
    printf "%s", s
  }'
}

json_str_or_null() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

emit_json() {
  if [ "$DUET_JSON_ENABLED" = "1" ]; then
    printf '%s\n' "$1"
  fi
}

say() {
  if [ "$DUET_JSON_ENABLED" != "1" ]; then
    printf '%s\n' "$*"
  fi
}

warn_msg() {
  _code="$1"
  _msg="$2"
  _rem="$3"
  if [ "$DUET_JSON_ENABLED" = "1" ]; then
    emit_json "{\"event\":\"warning\",\"code\":$(json_str_or_null "$_code"),\"message\":$(json_str_or_null "$_msg"),\"remediation\":$(json_str_or_null "$_rem")}"
  else
    printf '[duet-server] Warning (%s): %s\n' "$_code" "$_msg" >&2
    if [ -n "$_rem" ]; then
      printf '[duet-server] Hint: %s\n' "$_rem" >&2
    fi
  fi
}

die() {
  _code="$1"
  _msg="$2"
  _rem="$3"
  if [ "$DUET_JSON_ENABLED" = "1" ]; then
    emit_json "{\"event\":\"error\",\"code\":$(json_str_or_null "$_code"),\"message\":$(json_str_or_null "$_msg"),\"remediation\":$(json_str_or_null "$_rem")}"
  else
    printf '[duet-server] Error (%s): %s\n' "$_code" "$_msg" >&2
    if [ -n "$_rem" ]; then
      printf '[duet-server] Remediation: %s\n' "$_rem" >&2
    fi
  fi
  exit 1
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT INT TERM

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

detect_distro() {
  DISTRO_ID="linux"
  DISTRO_LIKE=""
  if [ -r /etc/os-release ]; then
    DISTRO_ID="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || printf 'linux')"
    DISTRO_LIKE="$(awk -F= '/^ID_LIKE=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
  elif [ -f /etc/alpine-release ]; then
    DISTRO_ID="alpine"
  fi
  if [ -z "$DISTRO_ID" ]; then
    DISTRO_ID="linux"
  fi
}

pkg_install_hint() {
  _deb_pkgs="$1"
  _apk_pkgs="$2"
  _rpm_pkgs="$3"
  _arch_pkgs="$4"
  _suse_pkgs="$5"

  _sudo=""
  if [ "$(id -u 2>/dev/null || printf '1000')" != "0" ]; then
    _sudo="sudo "
  fi

  case " $DISTRO_ID $DISTRO_LIKE " in
    *" alpine "*)
      printf '%sapk add --no-cache %s' "$_sudo" "$_apk_pkgs"
      ;;
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*)
      printf '%sapt-get update && %sapt-get install -y %s' "$_sudo" "$_sudo" "$_deb_pkgs"
      ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*)
      if command -v dnf >/dev/null 2>&1; then
        printf '%sdnf install -y %s' "$_sudo" "$_rpm_pkgs"
      else
        printf '%syum install -y %s' "$_sudo" "$_rpm_pkgs"
      fi
      ;;
    *" arch "*|*" manjaro "*)
      printf '%spacman -S --noconfirm %s' "$_sudo" "$_arch_pkgs"
      ;;
    *" opensuse "*|*" sles "*|*" suse "*)
      printf '%szypper install -y %s' "$_sudo" "$_suse_pkgs"
      ;;
    *)
      printf 'Install %s using your system package manager and re-run.' "$_deb_pkgs"
      ;;
  esac
}

# Validate URL scheme and host safety.
# Arguments:
#   $1: URL string
#   $2: label (e.g. "manifest" | "download" | "enrollment")
#   $3: allow_local_http ("1" or "0")
# Sets RESULT_URL_IS_LOCAL_HTTP="1" or "0"
RESULT_URL_IS_LOCAL_HTTP="0"
validate_url() {
  _url="$1"
  _label="$2"
  _allow_local="$3"
  RESULT_URL_IS_LOCAL_HTTP="0"

  if [ -z "$_url" ]; then
    die "INSECURE_URL" "Empty ${_label} URL is not allowed." "Provide a valid https:// URL for ${_label}."
  fi

  case "$_url" in
    *[[:space:]]*)
      die "INSECURE_URL" "Invalid ${_label} URL contains whitespace." "Provide a valid https:// URL without spaces or control characters."
      ;;
  esac

  case "$_url" in
    https://*)
      _rest="${_url#https://}"
      _host="${_rest%%/*}"
      if [ -z "$_host" ]; then
        die "INSECURE_URL" "Malformed ${_label} HTTPS URL: $_url" "Provide a complete https:// URL with a valid hostname."
      fi
      return 0
      ;;
    http://*)
      if [ "$_allow_local" != "1" ]; then
        die "INSECURE_URL" "Refusing insecure non-HTTPS ${_label} URL: $_url" "Use an https:// URL (plain HTTP is rejected for remote downloads)."
      fi
      _rest="${_url#http://}"
      _authority="${_rest%%/*}"
      case "$_authority" in
        127.0.0.1|127.0.0.1:*|localhost|localhost:*|"[::1]"|"[::1]":*)
          RESULT_URL_IS_LOCAL_HTTP="1"
          return 0
          ;;
        *)
          die "INSECURE_URL" "Refusing insecure non-HTTPS ${_label} URL: $_url" "Use https:// for remote hosts; plain http:// is permitted only for loopback (127.0.0.1 / localhost / [::1]) test overrides."
          ;;
      esac
      ;;
    *)
      die "INSECURE_URL" "Unsupported URL scheme for ${_label}: $_url" "Only https:// URLs are supported."
      ;;
  esac
}

http_fetch_to_file() {
  _url="$1"
  _out="$2"
  _err_code="$3"
  _label="$4"
  _err_log="$TMP_DIR/fetch-err.log"
  : > "$_err_log"

  if [ "$DOWNLOADER" = "curl" ]; then
    if [ "$CURL_SUPPORTS_PROTO" = "1" ]; then
      case "$_url" in
        https://*)
          if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 "$_url" -o "$_out" 2>"$_err_log"; then
            return 0
          fi
          ;;
        http://*)
          if curl -fsSL --proto '=http,https' --proto-redir '=http,https' --connect-timeout 15 --max-time 300 "$_url" -o "$_out" 2>"$_err_log"; then
            return 0
          fi
          ;;
      esac
    else
      if curl -fsSL --connect-timeout 15 --max-time 300 "$_url" -o "$_out" 2>"$_err_log"; then
        return 0
      fi
    fi
  else
    if [ "$WGET_SUPPORTS_HTTPS_ONLY" = "1" ]; then
      case "$_url" in
        https://*)
          if wget -q --https-only --timeout=20 -O "$_out" "$_url" 2>"$_err_log"; then
            return 0
          fi
          ;;
        http://*)
          if wget -q --timeout=20 -O "$_out" "$_url" 2>"$_err_log"; then
            return 0
          fi
          ;;
      esac
    else
      if wget -q -O "$_out" "$_url" 2>"$_err_log"; then
        return 0
      fi
    fi
  fi

  _detail="$(tr '\n' ' ' < "$_err_log" 2>/dev/null | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' || true)"
  if [ -z "$_detail" ]; then
    _detail="request failed"
  fi
  die "$_err_code" "Failed to download ${_label} from ${_url}: ${_detail}" "Verify outbound connectivity, TLS CA certificates, and that ${_url} is reachable, or set DUET_SERVER_VERSION / DUET_SERVER_MANIFEST_URL."
}

compute_sha256() {
  _file="$1"
  if [ "$SHA_TOOL" = "sha256sum" ]; then
    sha256sum "$_file" | awk '{print tolower($1)}'
  else
    shasum -a 256 "$_file" | awk '{print tolower($1)}'
  fi
}

resolve_existing_path() {
  _p="$1"
  while [ -n "$_p" ] && [ ! -e "$_p" ]; do
    _parent="$(dirname "$_p")"
    if [ "$_parent" = "$_p" ]; then
      break
    fi
    _p="$_parent"
  done
  printf '%s' "$_p"
}

check_disk_space() {
  _target="$1"
  _min_mb="$2"
  _existing="$(resolve_existing_path "$_target")"
  if [ -z "$_existing" ] || [ ! -e "$_existing" ]; then
    die "DISK_FULL" "Cannot resolve filesystem path for disk check: $_target" "Ensure HOME or PREFIX points to a valid writable directory."
  fi

  _avail=""
  if df -Pm "$_existing" >/dev/null 2>&1; then
    _avail="$(df -Pm "$_existing" 2>/dev/null | awk 'END {print $4}')"
  else
    _avail_kb="$(df -k "$_existing" 2>/dev/null | awk 'END {print $4}')"
    case "$_avail_kb" in
      ''|*[!0-9]*) _avail="" ;;
      *) _avail=$((_avail_kb / 1024)) ;;
    esac
  fi

  case "$_avail" in
    ''|*[!0-9]*)
      die "DISK_FULL" "Unable to determine available disk space for ${_existing}." "Verify 'df -Pm ${_existing}' succeeds and ensures at least ${_min_mb} MB free."
      ;;
  esac

  DISK_FREE_MB="$_avail"
  DISK_CHECK_PATH="$_existing"

  if [ "$_avail" -lt "$_min_mb" ]; then
    die "DISK_FULL" "Insufficient disk space in ${_existing}: ${_avail} MB free, at least ${_min_mb} MB required." "Free at least ${_min_mb} MB in ${_existing} (e.g., inspect with 'du -sh ~/.cache ~/.local ~/* | sort -h', clean unused container/package caches, or set DUET_SERVER_DIR to a volume with >=${_min_mb} MB free) and re-run."
  fi
}

get_mode_octal() {
  _path="$1"
  if command -v stat >/dev/null 2>&1; then
    _raw="$(stat -c '%a' "$_path" 2>/dev/null || true)"
    case "$_raw" in
      [0-7][0-7][0-7]) printf '0%s' "$_raw"; return 0 ;;
      [0-7][0-7][0-7][0-7]) printf '%s' "$_raw"; return 0 ;;
    esac
  fi
  printf ''
}

semver_ge() {
  _have="${1#v}"
  _need="${2#v}"
  _have="${_have%%-*}"
  _need="${_need%%-*}"
  awk -v a="$_have" -v b="$_need" 'BEGIN {
    na = split(a, ha, ".")
    nb = split(b, hb, ".")
    n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) {
      va = (i <= na ? ha[i] + 0 : 0)
      vb = (i <= nb ? hb[i] + 0 : 0)
      if (va > vb) exit 0
      if (va < vb) exit 1
    }
    exit 0
  }'
}

# Parse manifest JSON cleanly in pure POSIX awk (works with gawk, mawk, BusyBox awk).
# Emits key=value lines for top-level metadata and the selected platform asset.
parse_manifest_awk() {
  _manifest_file="$1"
  _target_platform="$2"
  awk -v target="$_target_platform" '
  function trim_ws(    c) {
    while (pos <= n) {
      c = substr(src, pos, 1)
      if (c == " " || c == "\t" || c == "\r" || c == "\n") pos++
      else break
    }
  }
  function parse_string(    out, c, esc) {
    out = ""
    if (substr(src, pos, 1) != "\"") { err = "expected string"; return "" }
    pos++
    while (pos <= n) {
      c = substr(src, pos, 1)
      if (c == "\"") { pos++; return out }
      if (c == "\\") {
        pos++
        if (pos > n) { err = "unterminated escape"; return "" }
        esc = substr(src, pos, 1)
        if (esc == "\"" || esc == "\\" || esc == "/") out = out esc
        else if (esc == "n") out = out "\n"
        else if (esc == "r") out = out "\r"
        else if (esc == "t") out = out "\t"
        else out = out esc
        pos++
      } else {
        out = out c
        pos++
      }
    }
    err = "unterminated string"
    return ""
  }
  function parse_prim(    start, c) {
    start = pos
    while (pos <= n) {
      c = substr(src, pos, 1)
      if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break
      pos++
    }
    return substr(src, start, pos - start)
  }
  function path_prefix(d,    i, p) {
    p = ""
    for (i = 1; i <= d; i++) {
      if (keys[i] != "") {
        if (p != "") p = p "."
        p = p keys[i]
      }
    }
    return p
  }
  BEGIN { src = ""; err = "" }
  { src = src $0 "\n" }
  END {
    n = length(src)
    pos = 1
    depth = 0
    trim_ws()
    if (substr(src, pos, 1) != "{") {
      print "ERROR=root_not_object"
      exit 0
    }
    while (pos <= n && err == "") {
      trim_ws()
      if (pos > n) break
      c = substr(src, pos, 1)
      if (c == "{") {
        depth++
        stype[depth] = "obj"
        expect_key[depth] = 1
        keys[depth] = ""
        pos++
      } else if (c == "[") {
        depth++
        stype[depth] = "arr"
        expect_key[depth] = 0
        keys[depth] = ""
        pos++
      } else if (c == "}" || c == "]") {
        if (depth <= 0) { err = "unexpected_close"; break }
        depth--
        if (depth > 0) keys[depth] = ""
        pos++
        if (depth == 0) break
      } else if (c == ",") {
        if (stype[depth] == "obj") expect_key[depth] = 1
        pos++
      } else if (c == ":") {
        expect_key[depth] = 0
        pos++
      } else if (c == "\"") {
        val = parse_string()
        if (err != "") break
        if (stype[depth] == "obj" && expect_key[depth] == 1) {
          keys[depth] = val
        } else {
          full = path_prefix(depth)
          if (full == "version" || full == "release" || full == "tag" || full == "runtime" || full == "minNodeVersion" || full == "baseUrl") {
            gsub(/[\r\n]/, "", val)
            printf "M_%s=%s\n", full, val
          } else if (index(full, "assets." target ".") == 1) {
            sub_key = substr(full, length("assets." target ".") + 1)
            if (index(sub_key, ".") == 0) {
              gsub(/[\r\n]/, "", val)
              printf "A_%s=%s\n", sub_key, val
            }
          } else if (index(full, "assets.") == 1) {
            rem = substr(full, length("assets.") + 1)
            dot = index(rem, ".")
            if (dot > 1) {
              plat = substr(rem, 1, dot - 1)
              if (!seen_plat[plat]++) {
                if (avail_plats != "") avail_plats = avail_plats ","
                avail_plats = avail_plats plat
              }
            }
          }
          keys[depth] = ""
        }
      } else {
        val = parse_prim()
        if (val == "") { err = "unexpected_token"; break }
        if (val != "null") {
          full = path_prefix(depth)
          if (index(full, "assets." target ".") == 1) {
            sub_key = substr(full, length("assets." target ".") + 1)
            if (index(sub_key, ".") == 0) {
              printf "A_%s=%s\n", sub_key, val
            }
          }
        }
        keys[depth] = ""
      }
    }
    if (err != "") {
      print "ERROR=" err
    } else if (depth != 0) {
      print "ERROR=unterminated_json"
    } else {
      printf "AVAIL_PLATFORMS=%s\n", avail_plats
    }
  }
  ' "$_manifest_file"
}

run_preflight() {
  detect_distro

  if [ -z "${HOME:-}" ]; then
    die "INVALID_HOME" "HOME environment variable is not set." "Set HOME to a writable user directory and re-run."
  fi

  SERVER_DIR="${DUET_SERVER_DIR:-${HOME}/.duet/server}"
  BIN_DIR="${DUET_BIN_DIR:-${HOME}/.local/bin}"

  # 1. OS detection
  _raw_os="$(uname -s)"
  case "$_raw_os" in
    Linux) OS_NAME="linux" ;;
    Darwin)
      die "UNSUPPORTED_OS" "Duet Server host bootstrap only supports Linux hosts (detected macOS)." "On macOS, install the Duet Desktop app or CLI instead: curl -fsSL https://duet.lat/install.sh | bash"
      ;;
    *)
      die "UNSUPPORTED_OS" "Duet Server host bootstrap requires Linux (detected: $_raw_os)." "Run this installer on a supported Linux host (x64 or arm64) or inside WSL2."
      ;;
  esac

  # 2. CPU architecture detection
  _raw_arch="$(uname -m)"
  case "$_raw_arch" in
    x86_64|amd64) ARCH_NAME="x64" ;;
    aarch64|arm64) ARCH_NAME="arm64" ;;
    *)
      die "UNSUPPORTED_ARCH" "Unsupported CPU architecture '$_raw_arch'. Duet Server supports x86_64/amd64 (x64) and aarch64/arm64 (arm64)." "Run on a Linux x64 or arm64 server."
      ;;
  esac

  # 3. Libc detection (glibc vs musl)
  LIBC_NAME="glibc"
  if is_truthy "${DUET_INSTALL_MUSL:-}" || is_truthy "${FABLE_INSTALL_MUSL:-}"; then
    LIBC_NAME="musl"
  elif ldd --version 2>&1 | grep -qi musl; then
    LIBC_NAME="musl"
  elif ls /lib/ld-musl-* >/dev/null 2>&1; then
    LIBC_NAME="musl"
  elif [ -f /etc/alpine-release ]; then
    LIBC_NAME="musl"
  fi

  if [ "$LIBC_NAME" = "musl" ]; then
    PLATFORM_KEY="linux-${ARCH_NAME}-musl"
  else
    PLATFORM_KEY="linux-${ARCH_NAME}"
  fi

  # 4. Required tools check
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
    if curl --help all 2>/dev/null | grep -q -- '--proto-redir' || curl --help 2>/dev/null | grep -q -- '--proto'; then
      CURL_SUPPORTS_PROTO="1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
    if wget --help 2>&1 | grep -q -- '--https-only'; then
      WGET_SUPPORTS_HTTPS_ONLY="1"
    fi
  else
    die "MISSING_TOOL" "Neither 'curl' nor 'wget' is installed." "$(pkg_install_hint "curl ca-certificates" "curl ca-certificates" "curl ca-certificates" "curl ca-certificates" "curl ca-certificates")"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_TOOL="shasum"
  else
    die "MISSING_TOOL" "Neither 'sha256sum' nor 'shasum' is available to verify download integrity." "$(pkg_install_hint "coreutils" "coreutils" "coreutils" "coreutils" "coreutils")"
  fi

  if command -v tar >/dev/null 2>&1; then
    HAS_TAR="1"
  fi
  if command -v unzip >/dev/null 2>&1; then
    HAS_UNZIP="1"
  fi
  if command -v gzip >/dev/null 2>&1; then
    HAS_GZIP="1"
  fi
  if [ "$HAS_TAR" != "1" ] && [ "$HAS_UNZIP" != "1" ]; then
    die "MISSING_TOOL" "An archive extraction tool ('tar' or 'unzip') is required." "$(pkg_install_hint "tar gzip unzip" "tar gzip unzip" "tar gzip unzip" "tar gzip unzip" "tar gzip unzip")"
  fi

  # 5. Disk space check (df -Pm ensuring >= MIN_DISK_MB in $HOME / $PREFIX / $SERVER_DIR)
  check_disk_space "$HOME" "$MIN_DISK_MB"
  if [ -n "${PREFIX:-}" ]; then
    check_disk_space "$PREFIX" "$MIN_DISK_MB"
  fi
  if [ "$SERVER_DIR" != "$HOME/.duet/server" ]; then
    check_disk_space "$SERVER_DIR" "$MIN_DISK_MB"
  fi

  # 6. SSH directory & permission sanity hints
  SSH_DIR_PRESENT="false"
  SSH_DIR_MODE=""
  SSH_AK_MODE=""
  SSH_WARN_DIR=""
  SSH_WARN_AK=""
  if [ -d "$HOME/.ssh" ]; then
    SSH_DIR_PRESENT="true"
    SSH_DIR_MODE="$(get_mode_octal "$HOME/.ssh")"
    if [ -n "$SSH_DIR_MODE" ] && [ "$SSH_DIR_MODE" != "0700" ]; then
      SSH_WARN_DIR="${HOME}/.ssh has mode ${SSH_DIR_MODE} (expected 0700); OpenSSH StrictModes may reject key authentication."
    fi
    if [ -f "$HOME/.ssh/authorized_keys" ]; then
      SSH_AK_MODE="$(get_mode_octal "$HOME/.ssh/authorized_keys")"
      if [ -n "$SSH_AK_MODE" ] && [ "$SSH_AK_MODE" != "0600" ] && [ "$SSH_AK_MODE" != "0400" ]; then
        SSH_WARN_AK="${HOME}/.ssh/authorized_keys has mode ${SSH_AK_MODE} (expected 0600); OpenSSH StrictModes may reject SSH key login."
      fi
    fi
  fi

  # 7. Service manager detection (systemd user/system vs container/nohup fallback)
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl --user show-environment >/dev/null 2>&1; then
      SERVICE_MODE="systemd-user"
    else
      SERVICE_MODE="systemd-no-user-bus"
    fi
  else
    SERVICE_MODE="container-nohup"
  fi

  # 8. Node.js readiness probe (non-fatal unless manifest runtime="node")
  if command -v node >/dev/null 2>&1; then
    NODE_VERSION="$(node -v 2>/dev/null || true)"
  fi

  # 9. Existing install state check (read-only)
  if [ -L "$SERVER_DIR/current" ] || [ -x "$SERVER_DIR/current/bin/duet-server" ]; then
    if [ -x "$SERVER_DIR/current/bin/duet-server" ]; then
      EXISTING_VERSION="$("$SERVER_DIR/current/bin/duet-server" --version 2>/dev/null | head -n 1 || true)"
    fi
  fi

  emit_json "{\"event\":\"preflight\",\"status\":\"ok\",\"os\":$(json_str_or_null "$OS_NAME"),\"arch\":$(json_str_or_null "$ARCH_NAME"),\"libc\":$(json_str_or_null "$LIBC_NAME"),\"platform\":$(json_str_or_null "$PLATFORM_KEY"),\"distro\":$(json_str_or_null "$DISTRO_ID"),\"downloader\":$(json_str_or_null "$DOWNLOADER"),\"checksumTool\":$(json_str_or_null "$SHA_TOOL"),\"hasTar\":$([ "$HAS_TAR" = "1" ] && printf true || printf false),\"hasUnzip\":$([ "$HAS_UNZIP" = "1" ] && printf true || printf false),\"nodeVersion\":$(json_str_or_null "$NODE_VERSION"),\"diskFreeMb\":${DISK_FREE_MB},\"diskMinMb\":${MIN_DISK_MB},\"diskPath\":$(json_str_or_null "$DISK_CHECK_PATH"),\"sshDirPresent\":${SSH_DIR_PRESENT},\"sshDirMode\":$(json_str_or_null "$SSH_DIR_MODE"),\"authorizedKeysMode\":$(json_str_or_null "$SSH_AK_MODE"),\"serviceMode\":$(json_str_or_null "$SERVICE_MODE"),\"installDir\":$(json_str_or_null "$SERVER_DIR"),\"binDir\":$(json_str_or_null "$BIN_DIR"),\"existingVersion\":$(json_str_or_null "$EXISTING_VERSION")}"

  say "Duet Server Bootstrap"
  say "---------------------"
  say "Platform: ${PLATFORM_KEY} (${DISTRO_ID}, ${LIBC_NAME})"
  say "Disk free: ${DISK_FREE_MB} MB in ${DISK_CHECK_PATH} (minimum ${MIN_DISK_MB} MB)"
  say "Service mode: ${SERVICE_MODE}"

  if [ -n "$SSH_WARN_DIR" ]; then
    warn_msg "SSH_DIR_PERMISSIONS" "$SSH_WARN_DIR" "chmod 700 ~/.ssh"
  fi
  if [ -n "$SSH_WARN_AK" ]; then
    warn_msg "SSH_AUTHORIZED_KEYS_PERMISSIONS" "$SSH_WARN_AK" "chmod 600 ~/.ssh/authorized_keys"
  fi
}

write_supervisor_script() {
  _dest="$1"
  _bin_path="$2"
  _tmp_sup="$TMP_DIR/duet-server-supervisor.sh"

  cat > "$_tmp_sup" <<EOF
#!/bin/sh
# Duet Server headless process supervisor (container/nohup fallback).
set -e

SERVER_DIR="\${DUET_SERVER_DIR:-${SERVER_DIR}}"
BIN_PATH="\${DUET_SERVER_BIN:-${_bin_path}}"
PID_FILE="\$SERVER_DIR/run/duet-server.pid"
LOG_FILE="\$SERVER_DIR/logs/duet-server.log"

mkdir -p "\$SERVER_DIR/run" "\$SERVER_DIR/logs"

is_running() {
  if [ -f "\$PID_FILE" ]; then
    _pid="\$(cat "\$PID_FILE" 2>/dev/null || true)"
    case "\$_pid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    if kill -0 "\$_pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

cmd="\${1:-status}"
case "\$cmd" in
  start)
    if is_running; then
      printf 'duet-server is already running (pid %s)\n' "\$(cat "\$PID_FILE")"
      exit 0
    fi
    nohup "\$BIN_PATH" serve >>"\$LOG_FILE" 2>&1 </dev/null &
    _pid=\$!
    printf '%s\n' "\$_pid" >"\$PID_FILE"
    printf 'duet-server started (pid %s, log %s)\n' "\$_pid" "\$LOG_FILE"
    ;;
  stop)
    if is_running; then
      _pid="\$(cat "\$PID_FILE")"
      kill "\$_pid" 2>/dev/null || true
      rm -f "\$PID_FILE"
      printf 'duet-server stopped (pid %s)\n' "\$_pid"
    else
      rm -f "\$PID_FILE"
      printf 'duet-server is not running\n'
    fi
    ;;
  restart)
    "\$0" stop
    "\$0" start
    ;;
  status)
    if is_running; then
      printf 'duet-server running (pid %s)\n' "\$(cat "\$PID_FILE")"
      exit 0
    fi
    printf 'duet-server stopped\n'
    exit 1
    ;;
  run)
    # Foreground supervision loop for container PID-1 / entrypoint usage.
    while :; do
      "\$BIN_PATH" serve >>"\$LOG_FILE" 2>&1 || true
      sleep 3
    done
    ;;
  *)
    printf 'Usage: %s {start|stop|restart|status|run}\n' "\$0" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "$_tmp_sup"
  if [ -f "$_dest" ] && cmp -s "$_tmp_sup" "$_dest" 2>/dev/null; then
    return 0
  fi
  mv "$_tmp_sup" "$_dest"
}

write_systemd_unit() {
  _unit_dest="$1"
  _bin_path="$2"
  _tmp_unit="$TMP_DIR/duet-server.service"
  _exec_bin="$_bin_path"
  if [ "$BIN_DIR" = "$HOME/.local/bin" ]; then
    _exec_bin="%h/.local/bin/duet-server"
  fi

  cat > "$_tmp_unit" <<EOF
[Unit]
Description=Duet Remote Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${_exec_bin} serve
WorkingDirectory=%h
Restart=on-failure
RestartSec=3
Environment=HOME=%h

[Install]
WantedBy=default.target
EOF
  if [ -f "$_unit_dest" ] && cmp -s "$_tmp_unit" "$_unit_dest" 2>/dev/null; then
    return 0
  fi
  mv "$_tmp_unit" "$_unit_dest"
}

setup_service() {
  _bin_path="$BIN_DIR/duet-server"
  SUPERVISOR_SCRIPT="$SERVER_DIR/duet-server-supervisor.sh"
  write_supervisor_script "$SUPERVISOR_SCRIPT" "$_bin_path"

  if [ "$SERVICE_MODE" = "systemd-user" ]; then
    _unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$_unit_dir"
    SERVICE_FILE="$_unit_dir/duet-server.service"
    write_systemd_unit "$SERVICE_FILE" "$_bin_path"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable duet-server.service >/dev/null 2>&1 || true
    if is_truthy "${DUET_START_SERVICE:-}" && ! is_truthy "${DUET_NO_START:-}"; then
      systemctl --user restart duet-server.service >/dev/null 2>&1 || true
    fi
    if command -v loginctl >/dev/null 2>&1; then
      _linger="$(loginctl show-user "$(id -un 2>/dev/null || printf '%s' "${USER:-}")" -p Linger 2>/dev/null || true)"
      if [ "$_linger" = "Linger=no" ]; then
        warn_msg "SYSTEMD_LINGER_DISABLED" "User systemd linger is disabled; background Vault/agent sync may stop after SSH logout." "sudo loginctl enable-linger $(id -un 2>/dev/null || printf '%s' "${USER:-${LOGNAME:-}}")"
      fi
    fi
  elif [ "$SERVICE_MODE" = "systemd-no-user-bus" ]; then
    SERVICE_FILE="$SERVER_DIR/duet-server.service"
    write_systemd_unit "$SERVICE_FILE" "$_bin_path"
    if is_truthy "${DUET_START_SERVICE:-}" && ! is_truthy "${DUET_NO_START:-}"; then
      "$SUPERVISOR_SCRIPT" start >/dev/null 2>&1 || true
    fi
  else
    SERVICE_FILE="$SUPERVISOR_SCRIPT"
    if is_truthy "${DUET_START_SERVICE:-}" && ! is_truthy "${DUET_NO_START:-}"; then
      "$SUPERVISOR_SCRIPT" start >/dev/null 2>&1 || true
    fi
  fi
}

setup_path_idempotent() {
  PATH_UPDATED="false"
  RC_FILE_USED=""
  if is_truthy "${DUET_NO_PATH:-}"; then
    return 0
  fi

  case ":${PATH:-}:" in
    *":${BIN_DIR}:"*)
      return 0
      ;;
  esac

  _rc=""
  case "${SHELL:-}" in
    *zsh) _rc="$HOME/.zshrc" ;;
    *bash) _rc="$HOME/.bashrc" ;;
  esac
  if [ -z "$_rc" ]; then
    if [ -f "$HOME/.bashrc" ]; then _rc="$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then _rc="$HOME/.zshrc"
    elif [ -f "$HOME/.profile" ]; then _rc="$HOME/.profile"
    else _rc="$HOME/.profile"
    fi
  fi

  if [ "$BIN_DIR" = "$HOME/.local/bin" ]; then
    # shellcheck disable=SC2016
    _path_line='export PATH="$HOME/.local/bin:$PATH"'
  else
    _path_line="export PATH=\"$BIN_DIR:\$PATH\""
  fi

  RC_FILE_USED="$_rc"
  if [ -f "$_rc" ] && grep -Fqx "$_path_line" "$_rc" 2>/dev/null; then
    return 0
  fi
  if [ -f "$_rc" ] && grep -Fq "$BIN_DIR" "$_rc" 2>/dev/null; then
    return 0
  fi

  if printf '\n%s\n' "$_path_line" >> "$_rc" 2>/dev/null; then
    PATH_UPDATED="true"
  fi
}

perform_enrollment() {
  _token="${DUET_ENROLL_TOKEN:-}"
  _enroll_url="${DUET_ENROLL_URL:-}"
  ENROLLED="false"
  ENROLL_STATUS="skipped"

  if [ -z "$_token" ]; then
    emit_json "{\"event\":\"enroll\",\"status\":\"skipped\",\"maxComputers\":5,\"nextStep\":\"Link this server as 1 of your 5 registered Duet computers via Duet Desktop (Add your own server) or 'duet-server link'.\"}"
    return 0
  fi

  if [ -n "$_enroll_url" ]; then
    validate_url "$_enroll_url" "enrollment" "1"
    _host_name="$(uname -n 2>/dev/null || printf 'linux-server')"
    _enroll_cfg="$TMP_DIR/enroll-curl.cfg"
    _enroll_body="$TMP_DIR/enroll-body.json"
    _enroll_resp="$TMP_DIR/enroll-resp.json"
    _enroll_err="$TMP_DIR/enroll-err.log"

    printf '{"hostname":"%s","platform":"%s","arch":"%s","serviceMode":"%s"}\n' \
      "$(json_escape "$_host_name")" \
      "$(json_escape "$PLATFORM_KEY")" \
      "$(json_escape "$ARCH_NAME")" \
      "$(json_escape "$SERVICE_MODE")" > "$_enroll_body"
    chmod 0600 "$_enroll_body"

    if [ "$DOWNLOADER" = "curl" ]; then
      (
        umask 077
        printf 'header = "Authorization: Bearer %s"\n' "$(printf '%s' "$_token" | tr -d '\r\n')" > "$_enroll_cfg"
        printf 'header = "Content-Type: application/json"\n' >> "$_enroll_cfg"
      )
      if [ "$CURL_SUPPORTS_PROTO" = "1" ]; then
        case "$_enroll_url" in
          http://*)
            if ! curl -fsSL --proto '=http,https' --proto-redir '=http,https' --connect-timeout 15 --max-time 30 -K "$_enroll_cfg" -X POST --data-binary "@$_enroll_body" "$_enroll_url" -o "$_enroll_resp" 2>"$_enroll_err"; then
              _edetail="$(tr '\n' ' ' < "$_enroll_err" 2>/dev/null || true)"
              rm -f "$_enroll_cfg" "$_enroll_body"
              die "ENROLL_FAILED" "Server enrollment request to ${_enroll_url} failed: ${_edetail:-request error}" "Verify your enrollment token is valid, you have fewer than 5 registered Duet computers, and ${_enroll_url} is reachable."
            fi
            ;;
          *)
            if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 30 -K "$_enroll_cfg" -X POST --data-binary "@$_enroll_body" "$_enroll_url" -o "$_enroll_resp" 2>"$_enroll_err"; then
              _edetail="$(tr '\n' ' ' < "$_enroll_err" 2>/dev/null || true)"
              rm -f "$_enroll_cfg" "$_enroll_body"
              die "ENROLL_FAILED" "Server enrollment request to ${_enroll_url} failed: ${_edetail:-request error}" "Verify your enrollment token is valid, you have fewer than 5 registered Duet computers, and ${_enroll_url} is reachable."
            fi
            ;;
        esac
      else
        if ! curl -fsSL --connect-timeout 15 --max-time 30 -K "$_enroll_cfg" -X POST --data-binary "@$_enroll_body" "$_enroll_url" -o "$_enroll_resp" 2>"$_enroll_err"; then
          _edetail="$(tr '\n' ' ' < "$_enroll_err" 2>/dev/null || true)"
          rm -f "$_enroll_cfg" "$_enroll_body"
          die "ENROLL_FAILED" "Server enrollment request to ${_enroll_url} failed: ${_edetail:-request error}" "Verify your enrollment token is valid, you have fewer than 5 registered Duet computers, and ${_enroll_url} is reachable."
        fi
      fi
      rm -f "$_enroll_cfg" "$_enroll_body"
    else
      _auth_hdr="Authorization: Bearer $(printf '%s' "$_token" | tr -d '\r\n')"
      if ! wget -q --timeout=30 --header="$_auth_hdr" --header="Content-Type: application/json" --post-file="$_enroll_body" -O "$_enroll_resp" "$_enroll_url" 2>"$_enroll_err"; then
        _edetail="$(tr '\n' ' ' < "$_enroll_err" 2>/dev/null || true)"
        rm -f "$_enroll_body"
        die "ENROLL_FAILED" "Server enrollment request to ${_enroll_url} failed: ${_edetail:-request error}" "Verify your enrollment token is valid, you have fewer than 5 registered Duet computers, and ${_enroll_url} is reachable."
      fi
      rm -f "$_enroll_body"
    fi

    ENROLLED="true"
    ENROLL_STATUS="enrolled"
    emit_json "{\"event\":\"enroll\",\"status\":\"enrolled\",\"maxComputers\":5,\"enrollUrl\":$(json_str_or_null "$_enroll_url")}"
    return 0
  fi

  # No DUET_ENROLL_URL passed; check if the installed binary handles stdin token enrollment.
  if "$BIN_DIR/duet-server" enroll --help >/dev/null 2>&1; then
    if printf '%s\n' "$_token" | "$BIN_DIR/duet-server" enroll --token-stdin >/dev/null 2>&1; then
      ENROLLED="true"
      ENROLL_STATUS="enrolled"
      emit_json "{\"event\":\"enroll\",\"status\":\"enrolled\",\"maxComputers\":5}"
      return 0
    fi
    die "ENROLL_FAILED" "'duet-server enroll --token-stdin' failed." "Re-run 'duet-server link' interactively or supply DUET_ENROLL_URL along with --enroll-token."
  fi

  ENROLL_STATUS="pending-manual-link"
  warn_msg "ENROLL_URL_REQUIRED" "Enrollment token was provided without DUET_ENROLL_URL and the installed binary has no offline enroll command." "Pass DUET_ENROLL_URL=https://... or complete linking via Duet Desktop -> Add your own server."
  emit_json "{\"event\":\"enroll\",\"status\":\"pending\",\"maxComputers\":5,\"nextStep\":\"Complete linking via Duet Desktop or pass DUET_ENROLL_URL.\"}"
}

extract_and_stage() {
  _archive="$1"
  _stage_dir="$TMP_DIR/stage"
  _extract_dir="$TMP_DIR/extract"
  mkdir -p "$_stage_dir/bin" "$_extract_dir"

  case "$_archive" in
    *.tar.gz|*.tgz)
      if [ "$HAS_TAR" != "1" ] || [ "$HAS_GZIP" != "1" ]; then
        die "MISSING_TOOL" "Both 'tar' and 'gzip' are required to extract $(basename "$_archive")." "$(pkg_install_hint "tar gzip" "tar gzip" "tar gzip" "tar gzip" "tar gzip")"
      fi
      if ! tar -xzf "$_archive" -C "$_extract_dir" 2>"$TMP_DIR/extract.log"; then
        die "EXTRACT_FAILED" "Failed to extract $(basename "$_archive")." "Re-run the installer; if the problem persists, verify the release archive is not corrupted."
      fi
      ;;
    *.tar.xz|*.txz)
      if [ "$HAS_TAR" != "1" ] || ! command -v xz >/dev/null 2>&1; then
        die "MISSING_TOOL" "Both 'tar' and 'xz' are required to extract $(basename "$_archive")." "$(pkg_install_hint "tar xz-utils" "tar xz" "tar xz" "tar xz" "tar xz")"
      fi
      if ! tar -xJf "$_archive" -C "$_extract_dir" 2>"$TMP_DIR/extract.log"; then
        die "EXTRACT_FAILED" "Failed to extract $(basename "$_archive")." "Re-run the installer; if the problem persists, verify the release archive is not corrupted."
      fi
      ;;
    *.tar)
      if [ "$HAS_TAR" != "1" ]; then
        die "MISSING_TOOL" "'tar' is required to extract $(basename "$_archive")." "$(pkg_install_hint "tar" "tar" "tar" "tar" "tar")"
      fi
      if ! tar -xf "$_archive" -C "$_extract_dir" 2>"$TMP_DIR/extract.log"; then
        die "EXTRACT_FAILED" "Failed to extract $(basename "$_archive")." "Re-run the installer; if the problem persists, verify the release archive is not corrupted."
      fi
      ;;
    *.zip)
      if [ "$HAS_UNZIP" != "1" ]; then
        die "MISSING_TOOL" "'unzip' is required to extract $(basename "$_archive")." "$(pkg_install_hint "unzip" "unzip" "unzip" "unzip" "unzip")"
      fi
      if ! unzip -q "$_archive" -d "$_extract_dir" 2>"$TMP_DIR/extract.log"; then
        die "EXTRACT_FAILED" "Failed to extract $(basename "$_archive")." "Re-run the installer; if the problem persists, verify the release archive is not corrupted."
      fi
      ;;
    *)
      # Standalone raw executable binary
      cp "$_archive" "$_stage_dir/bin/duet-server"
      chmod 0755 "$_stage_dir/bin/duet-server"
      return 0
      ;;
  esac

  # Locate payload root inside extracted archive
  _payload_root=""
  if [ -f "$_extract_dir/bin/duet-server" ] || [ -f "$_extract_dir/duet-server" ]; then
    _payload_root="$_extract_dir"
  else
    for _cand in "$_extract_dir"/*; do
      if [ -d "$_cand" ] && { [ -f "$_cand/bin/duet-server" ] || [ -f "$_cand/duet-server" ]; }; then
        _payload_root="$_cand"
        break
      fi
    done
  fi

  if [ -z "$_payload_root" ]; then
    die "INVALID_ARTIFACT" "Archive $(basename "$_archive") does not contain a 'duet-server' executable." "Ensure the release manifest points to a valid Duet Server bundle."
  fi

  cp -Rp "$_payload_root"/. "$_stage_dir"/
  mkdir -p "$_stage_dir/bin"
  if [ ! -f "$_stage_dir/bin/duet-server" ] && [ -f "$_stage_dir/duet-server" ]; then
    mv "$_stage_dir/duet-server" "$_stage_dir/bin/duet-server"
  fi
  chmod 0755 "$_stage_dir/bin/duet-server"
}

print_usage() {
  cat <<'EOF'
Usage: install-server.sh [OPTIONS]

Bootstrap Duet Server on a Linux host (x64 or arm64).

Options:
  --json                 Emit structured single-line NDJSON progress events on stdout
  --version <ver>        Install specific release tag/version (default: server-v0.0.1)
  --manifest-url <url>   Override server manifest JSON URL (HTTPS required)
  --enroll-token <tok>   Enroll this server during install (never printed or logged)
  --enroll-url <url>     Enrollment endpoint URL (HTTPS required)
  --server-dir <dir>     Install base directory (default: ~/.duet/server)
  --bin-dir <dir>        User bin symlink directory (default: ~/.local/bin)
  --check-only           Run preflight validations only without downloading/installing
  --no-path              Do not modify shell startup files for PATH
  --no-start             Do not start background service after install
  -h, --help             Show this help message
EOF
}

main() {
  if is_truthy "${DUET_JSON:-}"; then
    DUET_JSON_ENABLED="1"
  fi
  for _arg in "$@"; do
    if [ "$_arg" = "--json" ]; then
      DUET_JSON_ENABLED="1"
      break
    fi
  done

  # Parse CLI arguments cleanly
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        DUET_JSON="1"
        DUET_JSON_ENABLED="1"
        shift
        ;;
      --version)
        [ "$#" -ge 2 ] || die "INVALID_ARGS" "--version requires a value." "Run with --help for usage."
        DUET_SERVER_VERSION="$2"
        shift 2
        ;;
      --version=*)
        DUET_SERVER_VERSION="${1#--version=}"
        shift
        ;;
      --manifest-url)
        [ "$#" -ge 2 ] || die "INVALID_ARGS" "--manifest-url requires a value." "Run with --help for usage."
        DUET_SERVER_MANIFEST_URL="$2"
        shift 2
        ;;
      --manifest-url=*)
        DUET_SERVER_MANIFEST_URL="${1#--manifest-url=}"
        shift
        ;;
      --enroll-token)
        [ "$#" -ge 2 ] || die "INVALID_ARGS" "--enroll-token requires a value." "Run with --help for usage."
        DUET_ENROLL_TOKEN="$2"
        shift 2
        ;;
      --enroll-token=*)
        DUET_ENROLL_TOKEN="${1#--enroll-token=}"
        shift
        ;;
      --enroll-url)
        [ "$#" -ge 2 ] || die "INVALID_ARGS" "--enroll-url requires a value." "Run with --help for usage."
        DUET_ENROLL_URL="$2"
        shift 2
        ;;
      --enroll-url=*)
        DUET_ENROLL_URL="${1#--enroll-url=}"
        shift
        ;;
      --server-dir)
        [ "$#" -ge 2 ] || die "INVALID_ARGS" "--server-dir requires a value." "Run with --help for usage."
        DUET_SERVER_DIR="$2"
        shift 2
        ;;
      --server-dir=*)
        DUET_SERVER_DIR="${1#--server-dir=}"
        shift
        ;;
      --bin-dir)
        [ "$#" -ge 2 ] || die "INVALID_ARGS" "--bin-dir requires a value." "Run with --help for usage."
        DUET_BIN_DIR="$2"
        shift 2
        ;;
      --bin-dir=*)
        DUET_BIN_DIR="${1#--bin-dir=}"
        shift
        ;;
      --check-only)
        DUET_CHECK_ONLY="1"
        shift
        ;;
      --no-path)
        DUET_NO_PATH="1"
        shift
        ;;
      --no-start)
        DUET_NO_START="1"
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        die "INVALID_ARGS" "Unknown argument: $1" "Run install-server.sh --help to see supported options."
        ;;
    esac
  done

  REPO="${DUET_SERVER_REPO:-$DEFAULT_REPO}"
  REQ_VERSION="${DUET_SERVER_VERSION:-$DEFAULT_VERSION}"
  MIN_DISK_MB="${DUET_MIN_DISK_MB:-$DEFAULT_MIN_DISK_MB}"

  case "$MIN_DISK_MB" in
    ''|*[!0-9]*) MIN_DISK_MB="$DEFAULT_MIN_DISK_MB" ;;
  esac

  case "$REQ_VERSION" in
    server-v*|v*) RELEASE_TAG="$REQ_VERSION" ;;
    *) RELEASE_TAG="server-v${REQ_VERSION}" ;;
  esac

  DEFAULT_MANIFEST_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/server-manifest.json"
  MANIFEST_URL="${DUET_SERVER_MANIFEST_URL:-$DEFAULT_MANIFEST_URL}"

  TMP_DIR="${TMPDIR:-/tmp}/duet-server-install-$$"
  mkdir -p "$TMP_DIR" || die "INSTALL_FAILED" "Unable to create temporary directory $TMP_DIR." "Check TMPDIR permissions and available disk space."
  chmod 0700 "$TMP_DIR" 2>/dev/null || true

  # Preflight validations
  run_preflight

  if is_truthy "${DUET_CHECK_ONLY:-}"; then
    emit_json "{\"event\":\"ready\",\"checkOnly\":true,\"platform\":$(json_str_or_null "$PLATFORM_KEY"),\"serviceMode\":$(json_str_or_null "$SERVICE_MODE")}"
    say "Preflight checks passed."
    exit 0
  fi

  # Validate & fetch manifest
  validate_url "$MANIFEST_URL" "manifest" "1"
  MANIFEST_IS_LOCAL_HTTP="$RESULT_URL_IS_LOCAL_HTTP"

  emit_json "{\"event\":\"download\",\"phase\":\"manifest\",\"url\":$(json_str_or_null "$MANIFEST_URL")}"
  say "Fetching server manifest..."

  MANIFEST_PATH="$TMP_DIR/server-manifest.json"
  http_fetch_to_file "$MANIFEST_URL" "$MANIFEST_PATH" "MANIFEST_FETCH_FAILED" "server manifest"

  PARSED_PATH="$TMP_DIR/manifest.parsed"
  parse_manifest_awk "$MANIFEST_PATH" "$PLATFORM_KEY" > "$PARSED_PATH"

  PARSE_ERR=""
  M_version=""
  M_release=""
  M_tag=""
  M_runtime=""
  M_minNodeVersion=""
  M_baseUrl=""
  A_file=""
  A_sha256=""
  A_url=""
  A_size=""
  A_runtime=""
  A_minNodeVersion=""
  AVAIL_PLATFORMS=""

  while IFS='=' read -r _k _v; do
    case "$_k" in
      ERROR) PARSE_ERR="$_v" ;;
      M_version) M_version="$_v" ;;
      M_release) M_release="$_v" ;;
      M_tag) M_tag="$_v" ;;
      M_runtime) M_runtime="$_v" ;;
      M_minNodeVersion) M_minNodeVersion="$_v" ;;
      M_baseUrl) M_baseUrl="$_v" ;;
      A_file) A_file="$_v" ;;
      A_sha256) A_sha256="$_v" ;;
      A_url) A_url="$_v" ;;
      A_size) A_size="$_v" ;;
      A_runtime) A_runtime="$_v" ;;
      A_minNodeVersion) A_minNodeVersion="$_v" ;;
      AVAIL_PLATFORMS) AVAIL_PLATFORMS="$_v" ;;
    esac
  done < "$PARSED_PATH"

  if [ -n "$PARSE_ERR" ]; then
    die "INVALID_MANIFEST" "Server manifest at ${MANIFEST_URL} is not valid JSON (${PARSE_ERR})." "Verify the manifest URL points to a valid Duet Server JSON manifest."
  fi

  if [ -z "$A_file" ] || [ -z "$A_sha256" ]; then
    die "UNSUPPORTED_TARGET" "No server release asset found for platform '${PLATFORM_KEY}' in manifest (available: ${AVAIL_PLATFORMS:-none})." "Check supported Linux targets (linux-x64, linux-arm64, linux-x64-musl, linux-arm64-musl) or override DUET_SERVER_MANIFEST_URL."
  fi

  case "$A_file" in
    */*|*..*)
      die "INVALID_MANIFEST" "Unsafe asset file name in manifest: ${A_file}" "Manifest 'file' must be a plain filename without path separators."
      ;;
  esac

  EXPECTED_SHA="$(printf '%s' "$A_sha256" | tr '[:upper:]' '[:lower:]')"
  case "$EXPECTED_SHA" in
    ????????????????????????????????????????????????????????????????)
      case "$EXPECTED_SHA" in
        *[!0-9a-f]*)
          die "INVALID_MANIFEST" "Invalid SHA-256 digest format in manifest for ${PLATFORM_KEY}." "Ensure the manifest provides a valid 64-character hex sha256 digest."
          ;;
      esac
      ;;
    *)
      die "INVALID_MANIFEST" "Invalid SHA-256 digest length in manifest for ${PLATFORM_KEY}." "Ensure the manifest provides a valid 64-character hex sha256 digest."
      ;;
  esac

  RESOLVED_VERSION="${M_version:-${M_release:-${M_tag:-$RELEASE_TAG}}}"
  RESOLVED_VERSION="${RESOLVED_VERSION#server-v}"
  RESOLVED_VERSION="${RESOLVED_VERSION#v}"
  if [ -z "$RESOLVED_VERSION" ]; then
    RESOLVED_VERSION="0.0.1"
  fi

  # Runtime check if manifest requires Node.js
  EFF_RUNTIME="${A_runtime:-${M_runtime:-bundled}}"
  EFF_MIN_NODE="${A_minNodeVersion:-${M_minNodeVersion:-$DEFAULT_MIN_NODE_VERSION}}"
  if [ "$EFF_RUNTIME" = "node" ]; then
    if [ -z "$NODE_VERSION" ]; then
      die "MISSING_NODE" "This Duet Server package requires Node.js >= ${EFF_MIN_NODE}, but 'node' was not found on PATH." "$(pkg_install_hint "nodejs" "nodejs" "nodejs" "nodejs" "nodejs22") (or install via nvm/fnm)"
    fi
    if ! semver_ge "$NODE_VERSION" "$EFF_MIN_NODE"; then
      die "NODE_VERSION_TOO_OLD" "Installed Node.js ${NODE_VERSION} is older than required ${EFF_MIN_NODE}." "Upgrade Node.js to >= ${EFF_MIN_NODE} (for example with nvm: 'nvm install 22 && nvm use 22') and re-run."
    fi
  fi

  # Determine artifact download URL + enforce strict HTTPS check
  if [ -n "$A_url" ]; then
    DOWNLOAD_URL="$A_url"
  elif [ -n "$M_baseUrl" ]; then
    DOWNLOAD_URL="${M_baseUrl%/}/${A_file}"
  elif [ -n "${DUET_SERVER_MANIFEST_URL:-}" ]; then
    _manifest_dir="${MANIFEST_URL%/*}"
    DOWNLOAD_URL="${_manifest_dir}/${A_file}"
  else
    _dl_tag="${M_release:-${M_tag:-$RELEASE_TAG}}"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${_dl_tag}/${A_file}"
  fi

  validate_url "$DOWNLOAD_URL" "artifact download" "$MANIFEST_IS_LOCAL_HTTP"

  emit_json "{\"event\":\"download\",\"phase\":\"artifact\",\"file\":$(json_str_or_null "$A_file"),\"version\":$(json_str_or_null "$RESOLVED_VERSION"),\"url\":$(json_str_or_null "$DOWNLOAD_URL")}"
  say "Downloading ${A_file} (${RESOLVED_VERSION})..."

  ARTIFACT_PATH="$TMP_DIR/$A_file"
  http_fetch_to_file "$DOWNLOAD_URL" "$ARTIFACT_PATH" "DOWNLOAD_FAILED" "Duet Server artifact ($A_file)"

  # Verify optional byte size if provided
  if [ -n "$A_size" ]; then
    case "$A_size" in
      ''|*[!0-9]*) ;;
      *)
        _actual_bytes="$(wc -c < "$ARTIFACT_PATH" | awk '{print $1}')"
        if [ "$_actual_bytes" != "$A_size" ]; then
          rm -f "$ARTIFACT_PATH"
          die "CHECKSUM_MISMATCH" "Downloaded file size mismatch for ${A_file}: expected ${A_size} bytes, got ${_actual_bytes} bytes. Nothing was installed." "Re-run the installer; if this persists on a mirror/proxy, verify the release artifact."
        fi
        ;;
    esac
  fi

  # Strict SHA-256 verification (fail closed before extracting or installing)
  ACTUAL_SHA="$(compute_sha256 "$ARTIFACT_PATH")"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    rm -f "$ARTIFACT_PATH"
    die "CHECKSUM_MISMATCH" "SHA-256 checksum mismatch for ${A_file} (expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}). Nothing was installed." "Delete any cached proxy copies and re-run; verify the release manifest at ${MANIFEST_URL} matches the published artifact."
  fi

  # Extract & stage into isolated temp directory
  extract_and_stage "$ARTIFACT_PATH"

  # Verify staged binary executes cleanly before swapping live directories
  BINARY_VERSION="$("$TMP_DIR/stage/bin/duet-server" --version 2>/dev/null | head -n 1 || true)"
  if ! "$TMP_DIR/stage/bin/duet-server" --version >/dev/null 2>&1; then
    die "BINARY_VERIFICATION_FAILED" "Downloaded duet-server binary failed '--version' execution check for ${PLATFORM_KEY}. Nothing was installed." "Verify the host matches ${PLATFORM_KEY} (${LIBC_NAME}) and has required shared libraries, or try another DUET_SERVER_VERSION."
  fi

  emit_json "{\"event\":\"verify\",\"status\":\"ok\",\"file\":$(json_str_or_null "$A_file"),\"sha256\":$(json_str_or_null "$ACTUAL_SHA"),\"binaryVersion\":$(json_str_or_null "$BINARY_VERSION")}"
  say "Verified SHA-256 (${ACTUAL_SHA})"

  # Atomic idempotent install to ~/.duet/server/ (preserving data/, config/, logs/, run/)
  mkdir -p "$HOME/.duet" "$SERVER_DIR" "$SERVER_DIR/releases" "$SERVER_DIR/config" "$SERVER_DIR/data" "$SERVER_DIR/logs" "$SERVER_DIR/run" "$BIN_DIR" \
    || die "INSTALL_FAILED" "Unable to create Duet Server directories under ${SERVER_DIR} or ${BIN_DIR}." "Check directory ownership and permissions, then re-run."
  chmod 0700 "$SERVER_DIR/config" "$SERVER_DIR/data" 2>/dev/null || true

  RELEASE_STAGE_DIR="$SERVER_DIR/releases/.staging-${RESOLVED_VERSION}-$$"
  RELEASE_FINAL_DIR="$SERVER_DIR/releases/${RESOLVED_VERSION}"
  RELEASE_BACKUP_DIR="$SERVER_DIR/releases/.prev-${RESOLVED_VERSION}-$$"

  rm -rf "$RELEASE_STAGE_DIR" "$RELEASE_BACKUP_DIR"
  cp -R "$TMP_DIR/stage" "$RELEASE_STAGE_DIR"

  if [ -e "$RELEASE_FINAL_DIR" ]; then
    mv "$RELEASE_FINAL_DIR" "$RELEASE_BACKUP_DIR"
  fi
  mv "$RELEASE_STAGE_DIR" "$RELEASE_FINAL_DIR"
  ln -sfn "releases/${RESOLVED_VERSION}" "$SERVER_DIR/current"
  rm -rf "$RELEASE_BACKUP_DIR"

  ln -sfn "$SERVER_DIR/current/bin/duet-server" "$BIN_DIR/duet-server"

  setup_path_idempotent
  setup_service

  # Persist install metadata atomically without touching data/ or config/
  _state_tmp="$TMP_DIR/install-state.json"
  _installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
  cat > "$_state_tmp" <<EOF
{"version":$(json_str_or_null "$RESOLVED_VERSION"),"releaseTag":$(json_str_or_null "$RELEASE_TAG"),"platform":$(json_str_or_null "$PLATFORM_KEY"),"sha256":$(json_str_or_null "$ACTUAL_SHA"),"serviceMode":$(json_str_or_null "$SERVICE_MODE"),"installedAt":$(json_str_or_null "$_installed_at")}
EOF
  mv "$_state_tmp" "$SERVER_DIR/install-state.json"

  emit_json "{\"event\":\"install\",\"status\":\"ok\",\"version\":$(json_str_or_null "$RESOLVED_VERSION"),\"installDir\":$(json_str_or_null "$SERVER_DIR"),\"symlink\":$(json_str_or_null "$BIN_DIR/duet-server"),\"pathUpdated\":${PATH_UPDATED},\"serviceMode\":$(json_str_or_null "$SERVICE_MODE"),\"serviceFile\":$(json_str_or_null "$SERVICE_FILE")}"

  # Optional enrollment
  perform_enrollment

  _reused_existing="false"
  if [ -n "$EXISTING_VERSION" ]; then
    _reused_existing="true"
  fi

  emit_json "{\"event\":\"ready\",\"version\":$(json_str_or_null "$RESOLVED_VERSION"),\"binary\":$(json_str_or_null "$BIN_DIR/duet-server"),\"installDir\":$(json_str_or_null "$SERVER_DIR"),\"serviceMode\":$(json_str_or_null "$SERVICE_MODE"),\"serviceFile\":$(json_str_or_null "$SERVICE_FILE"),\"supervisor\":$(json_str_or_null "$SUPERVISOR_SCRIPT"),\"enrolled\":${ENROLLED},\"enrollStatus\":$(json_str_or_null "$ENROLL_STATUS"),\"maxComputers\":5,\"vaultSyncReady\":true,\"reusedExisting\":${_reused_existing},\"pathUpdated\":${PATH_UPDATED}}"

  say ""
  say "Duet Server ${RESOLVED_VERSION} installed"
  say "  Binary:      ${BIN_DIR}/duet-server"
  say "  Server home: ${SERVER_DIR}"
  say "  Service:     ${SERVICE_MODE} (${SERVICE_FILE})"
  if [ "$PATH_UPDATED" = "true" ] && [ -n "$RC_FILE_USED" ]; then
    say "  PATH:        Added ${BIN_DIR} to ${RC_FILE_USED} (restart your shell or run: export PATH=\"${BIN_DIR}:\$PATH\")"
  fi
  say ""
  if [ "$ENROLLED" = "true" ]; then
    say "This server is enrolled as 1 of your 5 registered Duet computers."
  else
    say "Next steps (link as 1 of your 5 registered Duet computers & start Vault/agent sync):"
    say "  1. Link this server:"
    say "     - In Duet Desktop: Settings -> Computers -> Add your own server (SSH)"
    say "     - Or in this terminal: duet-server link"
  fi
  if [ "$SERVICE_MODE" = "systemd-user" ]; then
    say "  2. Manage background service & Vault/agent sync:"
    say "     systemctl --user enable --now duet-server.service"
    say "     sudo loginctl enable-linger \$(id -un)   # keep sync alive after SSH disconnect"
  else
    say "  2. Start background service & Vault/agent sync:"
    say "     ${SUPERVISOR_SCRIPT} start"
    say "     ${SUPERVISOR_SCRIPT} status"
  fi
}

main "$@"
