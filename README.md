# duet-install

Public installer for **Duet** — the coding agent from **Fondation**.

Fable is the sole provider. Duet runs on Fable's own models: **Lune I** and **Frontier I**.

This repository contains **only** the installer. It contains no Duet source code.

> This repository was previously named `fable-install`. The GitHub repo
> rename to `duet-install` has landed; the installer points at the new
> name. `duet-v0.0.1` (CLI version `0.0.1`) is the first public Duet release,
> published on 2026-11-22. Existing unprefixed `v0.0.x` tags/releases belong to
> legacy Fable releases and must never be reused, deleted, or overwritten.

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
`DUET_VERSION`, e.g. `DUET_VERSION=duet-v0.0.1`, to install a different
release; `FABLE_VERSION` still works as a fallback). If latest-release lookup
fails, the installer falls back to duet-v0.0.1. Your data in `~/.duet` is kept.

Version overrides are literal release tags, not normalized version numbers.
Use `duet-v0.0.1`, not `0.0.1` or `v0.0.1`: the latter forms are not aliases
for the Duet release and may select legacy Fable content or fail.

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

Each release ships one prebuilt binary per supported platform plus `SHA256SUMS`. The published `duet-v0.0.1` release has all eight platform assets; the exact file names and checksums are in [`versions.json`](versions.json). The manifest at tag `duet-v0.0.1` matches every entry in the published `SHA256SUMS`, and GitHub's latest-release endpoint currently resolves to `duet-v0.0.1`. Explicitly mark each intended release as Latest rather than relying on automatic version ordering. Keep the manifest present on `main` and at each release tag.

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

> duet-v0.0.1 note: the `sha256` values in `versions.json` are the real
> CLI 0.0.1 binary hashes, generated from the local release candidates.
> The installer refuses to install on any checksum mismatch, so a
> stale hash can never install a wrong binary; it just fails closed.

## Status

- Installer script: the recorded Linux x64 install check used an earlier published release; it does not certify installation of the current `duet-v0.0.1` release.
- Windows installer script: repository test notes record a run on Windows Server 2022 x64 with PowerShell 5.1 and 7. The published Windows binaries have not been run on Windows; ARM64 has not been tested.
- The `duet-v0.0.1` assets were cross-built together and their file formats were verified. Repository test notes report executing Linux x64 (glibc and musl) release candidates. macOS, Windows, and ARM64 binary execution is unverified.

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

---

## Repository layout

| Path | Role |
| --- | --- |
| `install.sh` | macOS/Linux installer (POSIX sh, bash-3.2 safe). Detects OS/arch/libc, resolves the release via `versions.json`, verifies SHA-256, installs `duet` plus `fable`/`tera` aliases into `$DUET_BIN_DIR` (default `~/.local/bin`) |
| `install.ps1` | Windows installer (PowerShell 5.1+ and 7), installing into `%LOCALAPPDATA%\FableCode\bin` (legacy folder name kept on purpose — it's on users' PATH) |
| `install-server.sh` | Idempotent Linux host bootstrap for Duet Desktop's remote-computer flow (`DUET_JSON=1` emits NDJSON for the SSH "Add your own server" flow) |
| `versions.json` | Release manifest: tag, version, per-platform file names and SHA-256. Served at `main/versions.json` and read by the installers and `duet update` |
| `desktop-manifest.example.json` | Template for a future Desktop release manifest |
| `scripts/test-install-server.sh` | Local test harness for `install-server.sh` |

## How the installer reaches users

`https://duet.lat/install.sh`, `install.ps1` and `install-server.sh` are `vercel.json` rewrites in **Duet-Website** pointing at **commit-pinned GitHub raw URLs** in `Fondation-Inc/Duet-Install`. So shipping an installer change takes three steps, all verified by Duet-Website's `npm run check:installers`:

1. Merge the change into this repo's `main` on GitLab.
2. Fast-forward the GitHub mirror `Fondation-Inc/Duet-Install` to the same commit (it is not automatic; compare SHAs with `git ls-remote`).
3. Bump the pinned URLs in Duet-Website's `vercel.json` if the target files moved.

Binaries themselves are downloaded from **GitHub Releases** in `Fondation-Inc/Duet-Install` — `versions.json` at the release tag is the manifest of record.

## Cutting a release

- Build the platform binaries from Duet-CLI (`apps/cli/script/package-release.ts` builds assets + `versions.json`; public builds need `DUET_PUBLIC_BUILD=1`).
- Attach `duet-bun-<os>-<arch>[.exe]` for every platform plus `SHA256SUMS` to a GitHub release tagged `duet-v<version>`.
- `duet update` reads `main/versions.json` and only upgrades to a higher semver; mark the intended release **Latest** explicitly.
- Never reuse or delete `v0.0.x` tags — they belong to legacy Fable releases (`fable-bun-*`).

## Installer environment variables

| Variable | Purpose |
| --- | --- |
| `DUET_VERSION` | Release tag to install (e.g. `duet-v0.0.1`); `FABLE_VERSION` is the fallback |
| `DUET_BIN_DIR` | Install directory (default `~/.local/bin`); `FABLE_BIN_DIR` fallback |
| `DUET_INSTALL_MUSL` | Force the musl build on ambiguous libc detection; `FABLE_INSTALL_MUSL` fallback |
| `DUET_JSON` | `install-server.sh` NDJSON output mode for Desktop's SSH flow |

## Related repositories

| Repo | Role |
| --- | --- |
| [Duet-CLI](https://gitlab.com/Leonnett/Duet-CLI) | Builds the binaries this repo distributes |
| [Duet-Website](https://gitlab.com/Leonnett/Duet-Website) | Serves the installer URLs via `vercel.json` rewrites |
| [Duet-Desktop](https://gitlab.com/Leonnett/Duet-Desktop) | Consumes `install-server.sh` for remote computers |
