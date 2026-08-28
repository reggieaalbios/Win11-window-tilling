# Phase 2 Product Contract

Status: Approved by owner on 2026-08-26  
Current delivery: script-first `dev` snapshot

## Product definition

A polished, keyboard-first Windows 11 desktop environment inspired by modern
Hyprland setups. The distribution owns dependency orchestration, portable
configuration, startup, diagnostics, repair, rollback, and uninstall—not just a
collection of dotfiles.

The first alpha reproduces the owner's current opinionated desktop. A settings
application and broad end-user customization are future scope.

## Supported baseline

| Decision | Phase 2 policy |
|---|---|
| Operating system | Windows 11 x64 only |
| Install scope | Current Windows user; elevate only operations that require it |
| Display support | One monitor is the validated alpha baseline; multi-monitor is experimental |
| Configuration mode | Opinionated defaults, with machine paths generated during install |
| Installer UI | Guided Windows PowerShell 5.1 CLI |
| Development distribution | Commit-resolved GitHub `dev` snapshot downloaded without Git |
| Stable distribution | None until the owner approves a tested commit, tag, and first release |

## Component classification

### Required runtime

| Component | Product role | Ownership and failure policy |
|---|---|---|
| Komorebi | Tiling window manager | Installer-managed config and startup; failure is fatal |
| YASB | Top bar, launcher, wallpaper UI, power menu | Installer-managed config and startup; failure is fatal |
| AutoHotkey v2 | Keyboard workflow and window automation | Installer-managed scripts and startup; failure is fatal |
| WezTerm | Styled terminal and dropdown terminal | Installer-managed config; failure is fatal |
| Oh My Posh | Shell prompt presentation | Installer-managed theme/profile integration; shell remains usable if initialization fails |
| zoxide | Shell navigation | Installer-managed profile integration; shell remains usable if initialization fails |
| CAVA | Audio visualizer used by the desktop UI | Exactly one owned instance; failure is degraded, repairable state |
| DWMBlurGlass | Required visual treatment | Required feature with guarded compatibility check, rollback, and a no-blur safe fallback |
| Wallpaper pack | Required visual baseline | Package only assets with documented redistribution rights |

“Fatal” means setup must report failure and offer rollback or repair. “Degraded”
means the desktop remains usable, setup reports the missing feature clearly, and
`Repair` can retry it. DWMBlurGlass must never leave DWM, Explorer, or the taskbar
in a broken state when compatibility or elevation fails.

### Build and local validation tooling

These are repository/developer dependencies and are not installed for users:

- script-first bootstrap and lifecycle engine
- local validation scripts (no GitHub CI)
- manifest/hash generation tools
- smoke-test fixtures

### Excluded from the product

- Flow Launcher and its residual AppData
- GlazeWM and Zebar
- legacy AutoHotkey power menu superseded by YASB
- dormant hover-focus implementation
- dormant Game Mode implementation
- unbound scratchpad helper
- machine logs, generated caches, backups, and transient state

Exclusion authorizes no deletion yet. Phase 3 must distinguish installer-owned
files from the owner's personal or recoverable data before cleanup.

## Configuration ownership

The repository becomes the source of truth for portable templates. Installation
must render or link deployed configurations without embedding
`C:\Users\patri`.

For the alpha, prefer generated/copy-based deployment over symlinks. Symlinks
make local development convenient but add privilege, relocation, Git, and
uninstall failure modes on clean machines. A developer-only link command may be
added later.

The installer owns only files recorded in its component manifest. Before
replacing an existing user file, it must create a timestamped backup and record
the original path and hash in installation state.

## Startup ownership

- `Komorebi Delayed Startup` is the sole desktop-stack startup owner.
- The duplicate `HKCU\Run\KomorebiDesktopStack` entry is migration input and is
  removed only after the scheduled task is verified.
- DWMBlurGlass may retain a separate elevated startup task when required by its
  upstream design, but the installer must record and remove that task.
- Startup actions must be idempotent and must prevent duplicate AHK, YASB, CAVA,
  and Komorebi instances.
- A failed auxiliary component must not block sign-in or display modal dialogs.

## Installer lifecycle contract

`install.ps1` provides guided installation and delegates deterministic work to
the lifecycle module. The same engine supports:

- install and complete-stack reinstall
- guarded non-interactive install with meaningful exit codes
- repair
- diagnostics (`doctor`)
- uninstall

The component manifest records stable source identity, minimum capability,
health checks, install method, configuration files, startup ownership,
detection, repair, and uninstall behavior. Only patched and Windows-sensitive
exceptions record immutable versions and hashes.

Install and upgrade must be resumable. Each mutating step records completion so
that a failure can roll back the current component without guessing what was
changed.

## Upgrade, uninstall, and user-data policy

- Upgrades back up changed user files before applying a new managed version.
- Uninstall restores managed configuration and startup baselines. Dependencies
  remain installed unless the user explicitly selects their removal.
- Uninstall restores pre-install files when a recorded backup exists.
- User-created files and the existing
  `C:\Users\patri\Pictures\Wallpapers` collection are preserved.
- Bundled wallpapers live in an installer-owned location; uninstall may remove
  only the shipped files whose recorded hashes still match.
- Logs and installation state are retained only when the user chooses to keep
  diagnostics.

## Security and compatibility contract

- Every downloaded artifact must have an approved stable upstream source.
  Patched or Windows-build-sensitive exceptions use immutable version and hash
  locks; ordinary healthy packages are capability-detected and left in place.
- Redistribution and attribution must be documented for wallpapers, SVGs,
  themes, fonts, and bundled binaries before release.
- Elevation is requested only for the exact component step that requires it.
- DWMBlurGlass receives a preflight compatibility check, restore point or
  equivalent rollback material where available, and an explicit recovery path.
- The bootstrap records its resolved commit and archive hash. No product is
  released until the owner approves the exact tested commit.

## Acceptance states

### Success

- Required processes and exactly one intended instance are running.
- YASB widgets and their CapsLock/keyboard actions resolve to the native YASB
  implementations.
- Komorebi uses the installed portable configuration.
- WezTerm opens with the managed theme and PowerShell initializes Oh My Posh and
  zoxide without errors.
- The intended wallpaper source is available.
- Startup survives sign-out/sign-in with no duplicate stack owner.
- `doctor` reports a healthy installation.

### Degraded success

Only explicitly degradable visual/auxiliary features may enter this state.
Setup names the failed component, preserves a usable Windows desktop, and offers
repair. DWMBlurGlass incompatibility results in safe no-blur mode, not a damaged
shell.

### Failure

A core component cannot be installed/configured, startup cannot be made safe,
or rollback cannot be guaranteed. Setup reports failure and restores the last
known usable state.

## Validation boundary for the first alpha

The first alpha is accepted with a deliberately small test set:

1. Local manifest, syntax, path-portability, and idempotency checks.
2. Install on the controlled Windows 11 machine with none of the stack present.
3. Verify the core hotkeys/UI, terminal profile, wallpaper flow, and one-instance
   process state.
4. Sign out/in and repeat the health check.
5. Run repair, then uninstall and verify restoration.

Multi-monitor, non-English Windows, ARM64, enterprise policy environments, and
broad hardware compatibility remain explicitly unverified in the first alpha.

## Gate checklist

Phase 2 can close when the owner approves:

- the required/excluded component lists
- Windows 11 x64, current-user, single-monitor alpha scope
- safe-fallback treatment for DWMBlurGlass
- copy/render deployment instead of end-user symlinks
- scheduled task as sole desktop-stack startup owner
- backup/restore and wallpaper preservation policy
- the three acceptance states and minimal alpha test boundary

After approval, Phase 3 may perform controlled cleanup and migration preparation.
