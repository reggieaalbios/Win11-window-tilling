# Win11 Window Tiling

A keyboard-first Windows 11 desktop stack installed and maintained by PowerShell. The repository is the product: there is no executable installer, product prerelease, or automatic publishing workflow.

The managed stack includes Komorebi, patched YASB, AutoHotkey v2, WezTerm, Oh My Posh, zoxide, CAVA, DWMBlurGlass, adaptive themes, wallpapers, and the portable configuration set in this repository.

## Stable install

The normal installer follows `main`, which contains only the fully tested stable configuration:

```powershell
irm https://raw.githubusercontent.com/reggieaalbios/Win11-window-tilling/main/bootstrap.ps1 | iex
```

## Development install

To test the current `dev` state explicitly:

```powershell
irm https://raw.githubusercontent.com/reggieaalbios/Win11-window-tilling/dev/bootstrap-dev.ps1 | iex
```

`bootstrap-dev.ps1` is the dedicated development entrypoint and always selects `dev`. The development installer may contain changes that have passed local checks but not yet completed physical acceptance.

The bootstrap requires Windows PowerShell 5.1 but does not require Git. It checks for an existing installation before any download, resolves the selected branch to a commit, records the archive SHA-256, validates the snapshot structure, and then starts the visible CLI. UAC is requested once when machine-level changes begin.

Run a checked-out snapshot directly:

```powershell
.\install.ps1 -Action Install -MainModifier Win
.\install.ps1 -Action Repair -MainModifier Caps
.\install.ps1 -Action Doctor
.\install.ps1 -Action Uninstall
```

Completely purge the desktop stack, including configs, startup entries,
product caches, bundled wallpapers, and declared dependencies:

```powershell
.\self-destruct.ps1
.\self-destruct.ps1 -Force -NonInteractive
```

`Win` is the portable default. `Caps` preserves the personal Caps/F13 mapping. A non-interactive reinstall additionally requires `-ForceReinstall`.

All source snapshots, caches, state, backups, and JSONL logs remain below `%LOCALAPPDATA%\Win11WindowTilling`. No telemetry is collected or uploaded.

## Dependency policy

Healthy ordinary dependencies are kept regardless of patch version. Missing or incapable ordinary dependencies receive the current stable WinGet package; the installer never opts into prerelease or nightly sources and Repair does not silently upgrade healthy tools. AutoHotkey must be v2.

Patched YASB is an immutable, hash-verified dependency asset because upstream lacks WWT's native shortcut and popup coordination patch. DWMBlurGlass is also pinned through a tested Windows-build mapping. Their locks live in `manifests\immutable-assets.json`; ordinary packages are described by identity and capability in `manifests\components.json`.

## Local validation

This solo project intentionally has no GitHub CI. Run the full non-destructive local suite before promoting a commit to `main`:

```powershell
.\tests\local-validation.ps1
.\scripts\test-portability.ps1
.\scripts\test-adaptive-theme.ps1
.\scripts\test-lifecycle-state.ps1
```

Physical Windows 11 lifecycle checks remain mandatory after these scripts pass. See [local acceptance](docs/local-acceptance.md).

## Branch stability

This project does not publish product releases or use product tags. `dev` contains the current development state. `main` contains only the fully tested, owner-approved stable installer-script state. Promotion from `dev` to `main` is an explicit merge after local and physical acceptance.
