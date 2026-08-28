# Script-first installer architecture

`bootstrap.ps1` performs pre-download existing-install detection, immutable commit resolution, archive hashing, structure validation, snapshot storage, and CLI handoff. It never changes desktop state.

`install.ps1` owns the guided actions (`Install`, `Reinstall`, `Repair`, `Doctor`, and `Uninstall`), elevation, stage display, total progress, and final reporting. The lifecycle engine in `src/Win11WindowTiling.psm1` owns paths, JSONL logs, checkpoints, component inventory, configuration baselines, startup ownership, purge, restore, health, and dependency operations.

Reinstall follows a prepare-before-purge transaction: resolve and download the fresh stable set, inventory the current stack, stage recovery versions, back up declared targets and product state, stop processes, purge the complete declared stack, install, deploy configuration, and run Doctor. A failure after purge invokes rollback and preserves the exact failed stage in the local log.

Uninstall restores configuration and startup baselines while keeping dependencies by default. Dependency removal requires an explicit guided choice or `-RemoveDependencies`.

The declared destructive configuration targets are the complete Komorebi, YASB, and theme-engine directories plus managed WezTerm and PowerShell profile files. Only the WWT-named wallpaper asset is removed; unrelated wallpaper images remain untouched.
