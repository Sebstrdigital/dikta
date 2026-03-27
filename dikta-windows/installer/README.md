# Dikta Windows Installer

This directory contains the Inno Setup 6 script for building the Dikta Windows installer.

## Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Inno Setup 6](https://jrsoftware.org/isinfo.php) (Windows only — the script can be written on macOS but must be compiled on Windows)

## Step 1 — Publish the App

Run from the `dikta-windows/` directory:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -o publish/
```

This produces a self-contained win-x64 build in `dikta-windows/publish/`.

## Step 2 — Compile the Installer

On Windows, open Inno Setup 6 and compile `dikta-setup.iss`, or run from the command line:

```powershell
iscc.exe installer\dikta-setup.iss
```

The compiled installer is written to `installer\output\DiktaSetup-1.1.exe`.

## What the Installer Does

- Installs Dikta to `%ProgramFiles%\Dikta`
- Creates a Start Menu shortcut
- Offers an optional **Start at Login** checkbox (unchecked by default) that adds a registry entry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

## Uninstall

Uninstalling via **Windows Settings → Apps** removes:
- All app files from `%ProgramFiles%\Dikta`
- The Start Menu entry
- The `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Dikta` registry key (if Start at Login was enabled)

## Notes

- The script targets 64-bit Windows 10 (build 17763) or later.
- The `AppId` GUID in `dikta-setup.iss` must not be changed after the first public release — Windows uses it to identify the installed product for upgrades and uninstalls.
