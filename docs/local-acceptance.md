# Local acceptance and main-branch gate

Automated checks run locally, never in GitHub CI. A passing script suite proves parser, manifest, rendering, detection, decline, backup, and rollback invariants; it does not prove physical desktop behavior.

## Local scripts

Run from Windows PowerShell 5.1:

```powershell
.\tests\local-validation.ps1
.\scripts\test-portability.ps1
.\scripts\test-adaptive-theme.ps1
.\scripts\test-lifecycle-state.ps1
```

The lifecycle suite must cover a fresh plan, compatible-package skipping, AutoHotkey v1 rejection and v2 acceptance, the YASB fingerprint, zero-change `N`, confirmed purge, missing-state adoption, failure gates, rollback, Repair without upgrades, and dependency-preserving Uninstall.

## Physical Windows 11 matrix

Use a restorable Windows 11 x64 machine and record the exact `dev` commit and snapshot archive hash. Exercise first install, repeated `N`, repeated confirmed reinstall, sign-in and reboot startup, YASB popups, adaptive wallpaper colors, ordinary and dropdown terminal behavior, workspace controls, modifier dragging, DWMBlurGlass recovery, Repair, injected-failure rollback, and Uninstall.

Code/process checks cannot close physical interaction items. In particular, recreate affected windows and physically test drag, popup, focus, and startup behavior.

## Owner-only main promotion

This project has no product release or product-tag step. The owner explicitly chooses a `dev` commit only after local and physical acceptance, then merges that exact commit into `main`. Branch membership is the stability signal; there is no separate release-readiness flag.
