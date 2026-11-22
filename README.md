# duet-install

Public installer for **Duet** — the coding agent from **Fondation**.

Fable is the sole provider. Duet runs on Fable's own models: **Lune I** and **Frontier I**.

This repository contains **only** the installer. It contains no Duet source code.

> This repository was previously named `fable-install`. The GitHub repo
> rename to `duet-install` has landed; the installer points at the new
> name. v0.1.0 is the first release published as Duet.

## Install

macOS or Linux:

```sh
curl -fsSL https://duet.lat/install.sh | bash
```

Windows (PowerShell, not as Administrator):

```powershell
irm https://duet.lat/install.ps1 | iex
```

The installer downloads the prebuilt Duet binary for your platform from this repository's GitHub release, verifies its SHA-256 checksum, and installs it as `duet` in your user bin directory (`~/.local/bin` on macOS/Linux, `%LOCALAPPDATA%\FableCode\bin` on Windows). It also installs `fable` and `tera` as compatibility aliases for the same binary. The Windows folder name `FableCode` is kept on purpose: existing installs already have it on their user PATH.

No source checkout, no build step, no account needed to install. No other software is installed.

## Verify

```sh
duet --version
duet --help
duet doctor
```

## Update

Re-run the same install command to install the latest release (or set
`DUET_VERSION`, e.g. `DUET_VERSION=v0.1.0`, to install a different
release; `FABLE_VERSION` still works as a fallback). If latest-release lookup
fails, the installer falls back to v0.1.0. Your data in `~/.duet` is kept.

## Uninstall

Delete the installed files; your data in `~/.duet` is kept unless you delete it yourself.

macOS/Linux:

```sh
rm ~/.local/bin/duet ~/.local/bin/fable ~/.local/bin/tera
```

Windows (PowerShell):

```powershell
Remove-Item "$env:LOCALAPPDATA\FableCode\bin\duet.exe","$env:LOCALAPPDATA\FableCode\bin\fable.exe","$env:LOCALAPPDATA\FableCode\bin\tera.exe"
```

## Next steps

```sh
duet login      # Sign in with your Fable account
duet --help     # See all commands
```

Docs: https://www.fondation.ink/fable/docs/fable-code/install/

## Releases

Each release ships one prebuilt binary per supported platform plus `SHA256SUMS`. The exact file names and checksums for the current release are in [`versions.json`](versions.json).

Supported platforms:

| Platform | Binary |
| --- | --- |
| macOS arm64 (Apple Silicon) | `duet-bun-darwin-arm64` |
| macOS x64 (Intel) | `duet-bun-darwin-x64` |
| Linux x64 (glibc) | `duet-bun-linux-x64` |
| Linux x64 (musl, e.g. Alpine) | `duet-bun-linux-x64-musl` |
| Linux arm64 (glibc) | `duet-bun-linux-arm64` |
| Linux arm64 (musl, e.g. Alpine) | `duet-bun-linux-arm64-musl` |
| Windows x64 | `duet-bun-windows-x64.exe` |
| Windows arm64 | `duet-bun-windows-arm64.exe` |

> v0.1.0 note: the `sha256` values in `versions.json` are the real
> v0.1.0 binary hashes, generated from the published release assets.
> The installer refuses to install on any checksum mismatch, so a
> stale hash can never install a wrong binary; it just fails closed.

## Status

- macOS/Linux installer: verified on Linux x64 for v0.1.0 (anonymous install via the published release, `duet --version` and `fable --version` both print `0.1.0`, `duet doctor` exit 0; installed as `duet` with `fable`/`tera` aliases).
- Windows installer: verified natively on Windows Server 2022 x64 with PowerShell 5.1 and 7. ARM64 has not been tested.
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

`https://duet.lat/install-server.sh` serves `install-server.sh` from this repository's `main` branch.

> **Status:** no `server-v*` release with `server-manifest.json` and `duet-server` bundles has been published yet, so a default run passes preflight and then stops with `SERVER_RELEASE_NOT_FOUND`. Installs work once `server-v0.0.1` is published (or with `DUET_SERVER_MANIFEST_URL` pointing at a valid manifest).

### What `install-server.sh` checks and installs

1. **Preflight checks** with actionable, package-manager-aware remediation (`--check-only` runs preflight without downloading):
   - Linux OS, CPU architecture (`x86_64`/`amd64` -> `x64`, `aarch64`/`arm64` -> `arm64`), and `glibc` vs `musl` detection.
   - Required tools (`curl` or `wget`, `sha256sum` or `shasum`, and `tar`/`unzip` when extracting archives).
   - Disk space check via `df -Pm` ensuring at least `500` MB free in `$HOME` (and `$PREFIX` if set), failing with `DISK_FULL` when insufficient.
   - SSH sanity hints if `~/.ssh` is not mode `0700` or `~/.ssh/authorized_keys` is not mode `0600`.
   - Service supervision detection: `systemd --user` (`~/.config/systemd/user/duet-server.service`) when a user systemd bus is active, or a portable container/`nohup` supervisor script (`~/.duet/server/duet-server-supervisor.sh`) otherwise.
2. **Verified download & atomic install**:
   - Fetches `server-manifest.json` from `https://github.com/Fondation-Inc/Duet-Install/releases/download/<version>/server-manifest.json` (overridable via `DUET_SERVER_VERSION` and `DUET_SERVER_MANIFEST_URL`).
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
