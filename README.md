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

Re-run the same install command. It downloads the latest release and replaces the binary. Your data in `~/.fable` is kept.

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
