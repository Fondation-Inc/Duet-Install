# duet-install

Public installer for **Duet** — the coding agent from **Fondation**.

Fable is the sole provider. Duet runs on Fable's own models: **Lune I** and **Frontier I**.

This repository contains **only** the installer. It contains no Duet source code.

> This repository was previously named `fable-install`. The GitHub repo
> rename to `duet-install` is in progress; the installer already points
> at the new name, so do not cut the v0.0.10 release until the rename
> has landed.

## Install

macOS or Linux:

```sh
curl -fsSL https://duet.lat/install.sh | bash
```

Windows (PowerShell, not as Administrator):

```powershell
irm https://duet.lat/install.ps1 | iex
```

Transition: `duet.lat` is not pointed at the installer yet. Until the
DNS cutover, the same files are also served at
`https://fable.fondation.ink/install.sh` and
`https://fable.fondation.ink/install.ps1`.

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
`DUET_VERSION`, e.g. `DUET_VERSION=v0.0.10`, to install a different
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

> v0.0.10 note: the `sha256` values in `versions.json` are still the
> v0.0.9 binary hashes — the v0.0.10 binaries do not exist yet. They
> MUST be regenerated from the real v0.0.10 release assets before the
> release is published. The installer refuses to install on any
> checksum mismatch, so a stale hash can never install a wrong binary;
> it just fails closed.

## Status

- macOS/Linux installer: verified on Linux x64 for v0.0.8 (anonymous install, `fable --version`, `fable --help`, `fable doctor`). The v0.0.10 Duet installer flow (install as `duet` + `fable`/`tera` aliases) was verified locally against a simulated release — see the PR. It has **not** been run against the real v0.0.10 release yet, because that release does not exist.
- Windows installer: written from the macOS/Linux installer; **not tested on real Windows yet**. Treat it as untested until someone runs it on Windows and confirms `duet --version`.
- The other platform binaries are published from the same build and their file formats were verified, but they were not executed on their native platforms here.
