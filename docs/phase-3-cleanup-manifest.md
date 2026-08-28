# Phase 3 Cleanup Manifest

Status: Cleanup implemented; physical verification pending  
Started: 2026-08-26

This phase removes stale runtime ownership and unreachable configuration while
preserving recovery material. It does not uninstall applications or delete
personal data merely because they are excluded from the product.

## Recovery snapshot

Pre-change files and the complete HKCU Run key were copied to:

`%LOCALAPPDATA%\Win11WindowTilling\backups\phase3-20260826-1545`

## Approved cleanup actions

| Target | Evidence | Action | Recovery |
|---|---|---|---|
| `HKCU\Run\KomorebiDesktopStack` | Duplicates the successful `Komorebi Delayed Startup` scheduled task | Remove value after task verification | Import saved HKCU Run export |
| Orphan CAVA process | PID 3080 points to missing parent PID 4912; YASB owns the newer CAVA process | Stop orphan only | YASB can recreate its managed child |
| Hover-focus AHK code | Timer is disabled; leftover state writes still occur in launcher and Alt+Tab paths | Remove code and leftover state coupling | Restore saved AHK file |
| Game Mode AHK code/state | Startup call and hotkey are disabled | Remove unreachable code and state file | Restore saved AHK/state files |
| Legacy AHK power menu | No caller; YASB owns Ctrl+Alt+P | Remove functions | Restore saved AHK file |
| Scratchpad helper | No hotkey or caller | Remove variable and helper file | Restore saved AHK/helper files |

## Keep active

- Komorebi, YASB, AutoHotkey v2, WezTerm, Oh My Posh, zoxide, CAVA,
  DWMBlurGlass, and wallpapers
- `Komorebi Delayed Startup`
- DWMBlurGlass elevated startup task
- native YASB Quick Launch, Wallpapers, and power-menu implementations

## Deferred, not deleted

| Target | Reason |
|---|---|
| Flow Launcher residual AppData | Inactive but contains user-level state; archive/removal policy remains to be implemented |
| `.glzr\glazewm` and `.glzr\zebar` | Inactive product dependencies, but removal should follow installed-package ownership checks |
| `.glzr\glazewm-experimental` | Approximately 11.8 GB of source/build tooling and caches (`xwin`, LLVM, Rust target artifacts); keep until the owner separately approves removal |
| old startup shortcuts and Run-key backup files | Retain until startup behavior is validated after sign-out/sign-in |
| live logs and YASB style backups | Excluded from packaging; retain until migration baseline and rollback evidence are complete |

## Phase gate

Phase 3 closes when:

- AHK validates and the managed script is reloaded
- only the scheduled task owns desktop-stack startup
- one YASB-owned CAVA process remains
- Komorebi, YASB, Quick Launch, wallpaper UI, power menu, and workspace-only
  Alt+Tab still operate
- deferred data is documented and no personal data was deleted
- sign-out/sign-in persistence is either verified or explicitly recorded as
  pending physical validation

## Implementation result

- AutoHotkey parse validation succeeded after dormant code removal.
- The cleaned AutoHotkey script was reloaded and remained running.
- `HKCU\Run\KomorebiDesktopStack` was removed after the scheduled task reported
  result `0`.
- The orphan CAVA process was stopped; one CAVA child owned by YASB remains.
- Komorebi and YASB remained running.
- Static bindings remain for Caps+D Quick Launch, Caps+W Wallpapers,
  workspace-only Alt+Tab, and YASB's native Ctrl+Alt+P power menu.
- Physical hotkey behavior and sign-out/sign-in persistence are pending owner
  validation.
