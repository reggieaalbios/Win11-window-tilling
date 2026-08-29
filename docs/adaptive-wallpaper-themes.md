# Adaptive wallpaper themes

The bundled PowerShell theme engine derives a deterministic twelve-cluster
OKLab palette plus a chromatic hue histogram whenever YASB selects a wallpaper.
It selects three distinct wallpaper accents and maps them to semantic roles
rather than placing raw wallpaper colors directly into widgets.

The generated roles cover backgrounds, surfaces, text, muted text, borders,
accent, hover, active, focus, selection, status colors, and CAVA colors. WCAG
contrast checks are mandatory. Translucent YASB surfaces are additionally
tested after compositing over dark, median, and bright wallpaper samples. Text,
muted text, and borders must all pass on those composites. The engine raises
bar and popup opacity from glass-friendly floors of 78 and 88 percent, with
popups never above 94 percent.

## Managed surfaces

- YASB layout remains in `styles.layout.css`; generated colors are composed
  into `styles.css` and also stored in `styles.theme.css`.
- Komorebi receives distinct single, stack, monocle, floating/dropdown,
  unfocused, and locked border colors, pushed to the running manager immediately.
- WezTerm loads `wwt-theme.lua`; the existing `RESIZE` decoration and terminal
  behavior remain unchanged.
- Oh My Posh receives palette values without changing segment structure.
- Supported Windows DWM accent values are updated and broadcast to running
  applications.

## Recovery

Every application is transactional. Runtime state is stored below
`%LOCALAPPDATA%\Win11WindowTilling\themes`, including the palette cache, JSONL
log, active state, last-known-good state, and at most five committed snapshots.
An interrupted write is recovered at startup. A generation or decode failure
uses the bundled safe theme; it does not replace last-known-good.

Use `Caps+Ctrl+Backspace` for the safe theme. The command-line equivalents are:

```powershell
& "$env:USERPROFILE\.config\theme-engine\theme-engine.ps1" -Mode ApplySafe
& "$env:USERPROFILE\.config\theme-engine\theme-engine.ps1" -Mode RestoreLastGood
& "$env:USERPROFILE\.config\theme-engine\theme-engine.ps1" -Mode Doctor
```

Run the isolated integration test with:

```powershell
.\scripts\test-adaptive-theme.ps1
```

The test renders into a temporary synthetic user profile, disables runtime
reload and system-accent writes, and never changes the live desktop.
