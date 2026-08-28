# Phase 4 Portable Source Configurations

Status: Implemented and statically validated  
Completed: 2026-08-26

## Source-of-truth layout

| Repository path | Deployment destination |
|---|---|
| `config/komorebi` | `%USERPROFILE%\.config\komorebi` |
| `config/yasb` | `%USERPROFILE%\.config\yasb` |
| `config/ohmyposh` | `%USERPROFILE%\.config\ohmyposh` |
| `config/wezterm/.wezterm.lua` | `%USERPROFILE%\.wezterm.lua` |
| `config/powershell/Microsoft.PowerShell_profile.ps1` | `%USERPROFILE%\Documents\WindowsPowerShell` |

Logs, generated state, disabled startup links, historical backups, personal
wallpaper files, Flow Launcher, GlazeWM, and Zebar data are not source inputs.

## Portability model

AutoHotkey and PowerShell discover standard Windows locations at runtime through
environment variables. YASB requires rendered absolute paths, so
`config/yasb/config.yaml.template` uses these installer tokens:

| Token | Meaning |
|---|---|
| `{{USER_PROFILE_WIN}}` | Windows user-profile path with backslashes |
| `{{USER_PROFILE_URI}}` | User-profile path with forward slashes for HTML image sources |
| `{{PROGRAM_FILES_WIN}}` | native Program Files directory |
| `{{WALLPAPER_DIR_YAML}}` | wallpaper directory escaped for YAML double quotes |

`scripts/render-config.ps1` renders the complete deployment tree without
changing live files. It rejects filesystem-root output and unresolved tokens.

`scripts/test-portability.ps1` renders for a synthetic account and checks:

- no development-user path leaks into output
- no unresolved template tokens remain
- all JSON files parse
- all PowerShell files parse
- AutoHotkey parses when AutoHotkey v2 is installed

WezTerm configuration was also loaded successfully using its installed CLI.
The current-user render produced byte-identical YASB YAML/CSS, WezTerm,
Komorebi JSON, and applications JSON compared with the live configuration.

## Intentional product behavior preserved

- CapsLock/F13 keyboard layer
- workspace-only Alt+Tab
- YASB-native Quick Launch, Wallpapers, and power menu
- independent 75-percent dropdown apps
- native taskbar suppression with recovery toggle
- WezTerm Acrylic presentation and pane controls
- Oh My Posh and zoxide PowerShell initialization
- scheduled-task startup script

The shortcut guide was corrected to match the active bindings: Alt moves a
window and Shift resizes it.

## Remaining portability risks

- WezTerm `initial_cols = 133` and `initial_rows = 30` were tuned for the
  owner's 144-DPI display. They remain visual defaults, not universal sizing.
- The first alpha validates a single monitor; multi-monitor behavior remains
  experimental.
- Komorebi gaps, resize delta, opacity, and YASB dimensions are opinionated
  product defaults and may look different at other DPI scales.
- Independent YAML parsing was unavailable because Python/PyYAML is not
  installed. The rendered current-user YAML is byte-identical to the active
  YASB configuration, and YASB is currently running with that configuration.
- YASB asset and wallpaper redistribution provenance is still required before
  packaging.
- The renderer stages files only. Backup-aware live deployment belongs to the
  installer foundation phase.

## Gate result

Phase 4 is ready to close. Portable templates and validation exist, the live
desktop was not replaced, and unresolved packaging/security concerns remain
explicitly deferred to their later gates.
