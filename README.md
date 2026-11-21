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

Re-run the same install command to reinstall the same release (or set
`DUET_VERSION`, e.g. `DUET_VERSION=v0.1.0`, to install a different
release; `FABLE_VERSION` still works as a fallback). Your data in
`~/.fable` is kept.

## Uninstall

Delete the installed files; your data in `~/.fable` is kept unless you delete it yourself.

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
- Windows installer: written from the macOS/Linux installer; **not tested on real Windows yet**. Treat it as untested until someone runs it on Windows and confirms `duet --version`.
- The other platform binaries are published from the same build and their file formats were verified, but they were not executed on their native platforms here.

---

## Duet Server Setup (`install-server.sh`)

Links a Linux server to the Duet app. In the app, open **Add your own server**; it shows a setup code. On the server:

```sh
curl -fsSL https://duet.lat/install-server.sh | sh -s -- <code> --cloudflare
```

(`--tailscale`, `--ssh` or `--relay` pick another way for the app to reach the server.)

`install-server.sh` checks the code and runs the setup script the Duet link service serves for it (`<link>/s/<code>[/<way>]`, or `<link>/i/<token>` for the app's long token). That script installs the server and reports each step to the app. The server build is private: the link service hands it only to the setup session the code names, so this repository publishes no server release and the script installs nothing without a code.

`DUET_LINK_BASE` overrides the link service (default `https://link.dusk.bot`, the one the Duet app uses; plain `http://` is allowed only for loopback tests).

```sh
./scripts/test-install-server.sh
```

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
