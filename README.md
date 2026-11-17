# fable-install

Public installer for **Fable Code** — the coding agent from **Fondation**.

Fable is the sole provider. Fable Code runs on Fable's own models: **Lune I** and **Frontier I**.

This repository contains **only** the installer. It contains no Fable Code source code.

## Install

macOS or Linux:

```sh
curl -fsSL https://fable.fondation.ink/install.sh | bash
```

Windows (PowerShell, not as Administrator):

```powershell
irm https://fable.fondation.ink/install.ps1 | iex
```

The installer downloads the prebuilt Fable Code binary for your platform from this repository's GitHub release, verifies its SHA-256 checksum, and installs it as `fable` in your user bin directory (`~/.local/bin` on macOS/Linux, `%LOCALAPPDATA%\FableCode\bin` on Windows). It also installs `tera` as a compatibility alias for the same binary.

No source checkout, no build step, no account needed to install. No other software is installed.

## Verify

```sh
fable --version
fable --help
fable doctor
```

## Update

Re-run the same install command to reinstall the same release (or set
`FABLE_VERSION`, e.g. `FABLE_VERSION=v0.0.5`, to install a different
release). Your data in `~/.fable` is kept.

## Uninstall

Delete the installed files; your data in `~/.fable` is kept unless you delete it yourself.

macOS/Linux:

```sh
rm ~/.local/bin/fable ~/.local/bin/tera
```

Windows (PowerShell):

```powershell
Remove-Item "$env:LOCALAPPDATA\FableCode\bin\fable.exe","$env:LOCALAPPDATA\FableCode\bin\tera.exe"
```

## Next steps

```sh
fable login     # Sign in with your Fable account
fable --help    # See all commands
```

Docs: https://www.fondation.ink/fable/docs/fable-code/install/

## Releases

Each release ships one prebuilt binary per supported platform plus `SHA256SUMS`. The exact file names and checksums for the current release are in [`versions.json`](versions.json).

Supported platforms:

| Platform | Binary |
| --- | --- |
| macOS arm64 (Apple Silicon) | `fable-bun-darwin-arm64` |
| macOS x64 (Intel) | `fable-bun-darwin-x64` |
| Linux x64 (glibc) | `fable-bun-linux-x64` |
| Linux x64 (musl, e.g. Alpine) | `fable-bun-linux-x64-musl` |
| Linux arm64 (glibc) | `fable-bun-linux-arm64` |
| Linux arm64 (musl, e.g. Alpine) | `fable-bun-linux-arm64-musl` |
| Windows x64 | `fable-bun-windows-x64.exe` |
| Windows arm64 | `fable-bun-windows-arm64.exe` |

## Status

- macOS/Linux installer: verified on Linux x64 (anonymous install, `fable --version`, `fable --help`, `fable doctor`).
- Windows installer: written from the macOS/Linux installer; **not tested on real Windows yet**. Treat it as untested until someone runs it on Windows and confirms `fable --version`.
- The other platform binaries are published from the same build and their file formats were verified, but they were not executed on their native platforms here.

---

## Duet Server Bootstrap (`install-server.sh`)

Idempotent one-line bootstrap for connecting a Linux host (`x64` or `arm64`, `glibc` or `musl`) to **Duet Desktop** as one of your **5 registered Duet computers** and running Vault/agent sync.

Interactive terminal:

```sh
curl -fsSL https://duet.lat/install-server.sh | bash
```

Structured NDJSON mode (used by Duet Desktop's SSH **Add your own server** flow):

```sh
curl -fsSL https://duet.lat/install-server.sh | DUET_JSON=1 bash
```

Until `duet.lat` DNS cutover is complete, the same script is hosted directly in this repository (`https://raw.githubusercontent.com/leonnett/duet-install/main/install-server.sh`).

### What `install-server.sh` checks and installs

1. **Preflight checks** with actionable, package-manager-aware remediation (`--check-only` runs preflight without downloading):
   - Linux OS, CPU architecture (`x86_64`/`amd64` -> `x64`, `aarch64`/`arm64` -> `arm64`), and `glibc` vs `musl` detection.
   - Required tools (`curl` or `wget`, `sha256sum` or `shasum`, and `tar`/`unzip` when extracting archives).
   - Disk space check via `df -Pm` ensuring at least `500` MB free in `$HOME` (and `$PREFIX` if set), failing with `DISK_FULL` when insufficient.
   - SSH sanity hints if `~/.ssh` is not mode `0700` or `~/.ssh/authorized_keys` is not mode `0600`.
   - Service supervision detection: `systemd --user` (`~/.config/systemd/user/duet-server.service`) when a user systemd bus is active, or a portable container/`nohup` supervisor script (`~/.duet/server/duet-server-supervisor.sh`) otherwise.
2. **Verified download & atomic install**:
   - Fetches `server-manifest.json` from `https://github.com/leonnett/duet-install/releases/download/<version>/server-manifest.json` (overridable via `DUET_SERVER_VERSION` and `DUET_SERVER_MANIFEST_URL`).
   - Enforces strict `https://` URLs for all remote fetches (plain `http://` is rejected unless pointing at loopback `127.0.0.1` / `localhost` / `[::1]` for local testing).
   - Verifies SHA-256 (fail closed on mismatch before extraction or installation) and runs `duet-server --version` before swapping `~/.duet/server/current` and linking `~/.local/bin/duet-server`.
   - Re-runs are idempotent: existing `~/.duet/server/{data,config,logs,run}` state, PATH entries, and service unit files are preserved without duplication.
3. **Enrollment & JSON events**:
   - Optional `--enroll-token` / `DUET_ENROLL_URL` enrollment (tokens are never logged or emitted to stdout/state files), or prints next steps to link the host as 1 of your 5 registered Duet computers and start Vault/agent sync.
   - With `DUET_JSON=1` (or `--json`), emits single-line JSON events (`preflight`, `warning`, `download`, `verify`, `install`, `enroll`, `ready`, `error`).

### Environment overrides & tests

| Variable | Purpose | Default |
| --- | --- | --- |
| `DUET_JSON` | Set `1` to emit single-line NDJSON events on stdout | `0` |
| `DUET_SERVER_VERSION` | Release tag or version to install | `server-v0.0.1` |
| `DUET_SERVER_MANIFEST_URL` | Override manifest JSON URL (staged rollouts / local tests) | GitHub release manifest |
| `DUET_SERVER_DIR` | Installation root preserving `data/` and `config/` | `~/.duet/server` |
| `DUET_BIN_DIR` | Target directory for the `duet-server` symlink | `~/.local/bin` |
| `DUET_ENROLL_TOKEN` | Optional enrollment bearer token (also `--enroll-token`) | unset |
| `DUET_ENROLL_URL` | Optional enrollment endpoint (also `--enroll-url`) | unset |

Verify locally with the mock HTTP test suite (cleans up `/tmp` automatically):

```sh
./scripts/test-install-server.sh
```

---

## Duet Desktop Release Channel (`desktop-v0.0.1`)

Public desktop installers and `electron-updater` channel `duet` metadata are hosted from GitHub Releases in this repository under tags like `desktop-v0.0.1`. See [`desktop-manifest.example.json`](desktop-manifest.example.json) for the canonical release asset layout:

| Platform / Feed | Asset |
| --- | --- |
| macOS Apple Silicon (`arm64`) | `Duet-0.0.1-arm64.dmg` |
| macOS Intel (`x64`) | `Duet-0.0.1-x64.dmg` |
| Windows (`x64`) | `Duet-0.0.1-x64.exe` |
| Linux (`x64`) | `Duet-0.0.1-x64.AppImage` |
| Linux (`arm64`) | `Duet-0.0.1-arm64.AppImage` |
| `electron-updater` macOS feed (`duet` channel) | `duet-mac.yml` |
| `electron-updater` Windows feed (`duet` channel) | `duet.yml` |
| `electron-updater` Linux feed (`duet` channel) | `duet-linux.yml` |
| Release checksums | `SHA256SUMS.txt` |

> Note: [`desktop-manifest.example.json`](desktop-manifest.example.json) documents the expected `desktop-v0.0.1` asset layout only; real SHA-256 digests and `electron-updater` YAML feeds are generated from signed release binaries when `desktop-v0.0.1` is published.
