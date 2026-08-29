#Requires AutoHotkey v2.0.2
#SingleInstance Force
; Keep startup warnings non-interactive so login never waits for an AutoHotkey dialog.
#Warn All, OutputDebug

; Parse-only entry point used to validate edits without touching the live
; Komorebi/AutoHotkey desktop session.
if A_Args.Length && A_Args[1] = "--validate"
    ExitApp()

ProgramFilesHome := EnvGet("ProgramFiles")
UserProfileHome := EnvGet("USERPROFILE")
LocalAppDataHome := EnvGet("LOCALAPPDATA")
KomorebicExe := ProgramFilesHome "\komorebi\bin\komorebic-no-console.exe"
KomorebiExe := ProgramFilesHome "\komorebi\bin\komorebi.exe"
YasbcExe := ProgramFilesHome "\YASB\yasbc.exe"
WezTermGuiExe := ProgramFilesHome "\WezTerm\wezterm-gui.exe"
BraveMachineExe := ProgramFilesHome "\BraveSoftware\Brave-Browser\Application\brave.exe"
BraveExe := FileExist(BraveMachineExe) ? BraveMachineExe : LocalAppDataHome "\BraveSoftware\Brave-Browser\Application\brave.exe"
ConfigHome := UserProfileHome "\.config\komorebi"
ConfigFile := ConfigHome "\komorebi.json"
ScreenshotHelper := ConfigHome "\capture-fullscreen.ps1"
ThemeEngine := UserProfileHome "\.config\theme-engine\theme-engine.ps1"
DropdownTitle := "Komorebi Dropdown PowerShell"
DropdownNotesFile := UserProfileHome "\Documents\Dropdown Notes.txt"
MainModifier := "{{MAIN_MODIFIER_AHK}}"
if MainModifier = "Caps"
    SetCapsLockState("AlwaysOff")
global ResizeMode := false
global WindowsTaskbarHidden := true
global FocusedWindowAlpha := 242
global ShellHookMessage := 0
global DropdownReturnFocus := Map()
global ManagedWindowRoles := Map()
global ManagedWorkspaceSnapshot := Map()
global LastManagedStateRefresh := 0
global LastBlockedTitleClickHwnd := 0
global LastBlockedTitleClickAt := 0
global ExplicitWorkspaceOneMonocle := false

; Read-only runtime probe used by the repository validation gate. It exercises
; the COM capture, JSON parser, and active-workspace classifier without starting
; Komorebi, timers, dropdowns, or any desktop hooks.
if A_Args.Length && A_Args[1] = "--test-managed-state"
    ExitApp(RefreshManagedWindowCache() ? 0 : 2)

Komorebic(command, wait := true) {
    global KomorebicExe
    if wait
        RunWait('"' KomorebicExe '" ' command, , "Hide")
    else
        Run('"' KomorebicExe '" ' command, , "Hide")
}

if !ProcessExist("komorebi.exe") {
    Run('"' KomorebiExe '" --config "' ConfigFile '"', , "Hide")
    if !ProcessWait("komorebi.exe", 10) {
        MsgBox("komorebi.exe did not start. GlazeWM remains disabled; use the migration backup to roll back.", "Komorebi startup failed", 16)
        ExitApp()
    }
    Sleep(1000)
}
SetTimer(EnsureKomorebiRunning, 10000)
InitializeWindowGlass()
SetTimer(KeepAllWindowsTranslucent, 500)
HideWindowsTaskbars()
ApplyKomorebiWorkArea()
SetTimer(HideWindowsTaskbars, 100)
; Cava's audio capture can remain attached to the pre-sleep audio session.
; Reload YASB once Windows Audio has had time to recover after wake.
OnMessage(0x0218, HandlePowerBroadcast)
; Seed a small fail-open cache for mouse hit-testing. It refreshes lazily on
; interaction instead of spawning a state process continuously in the background.
RefreshManagedWindowCache()
; Build the three dropdown windows as soon as this startup thread yields. The
; logon task already waits for Explorer, so no additional delay is needed here.
; They stay hidden, but their processes, renderers, and content are ready before
; the first Caps+Shift hotkey press.
SetTimer(PrewarmDropdownApps, -10)

EnsureKomorebiRunning() {
    global KomorebicExe, KomorebiExe, ConfigFile
    if ProcessExist("komorebi.exe") {
        try {
            if RunWait('"' KomorebicExe '" state', , "Hide") = 0
                return
        }
        try ProcessClose("komorebi.exe")
        Sleep(300)
    }
    try {
        Run('"' KomorebiExe '" --config "' ConfigFile '"', , "Hide")
        ProcessWait("komorebi.exe", 10)
    }
}

HandlePowerBroadcast(wParam, lParam, msg, hwnd) {
    ; PBT_APMRESUMESUSPEND (7) and PBT_APMRESUMEAUTOMATIC (18) may both
    ; arrive for one wake. Replacing the one-shot timer debounces them.
    if wParam = 7 || wParam = 18
        SetTimer(ReloadYasbAfterResume, -6000)
    return true
}

ReloadYasbAfterResume() {
    global YasbcExe
    if ProcessExist("yasb.exe") && FileExist(YasbcExe)
        Run('"' YasbcExe '" reload', , "Hide")
}

EnterResizeMode() {
    global ResizeMode
    ResizeMode := true
    TrayTip("Use H/J/K/L or arrows; Enter/Escape exits.", "Komorebi resize mode", 1)
}
ExitResizeMode() {
    global ResizeMode
    ResizeMode := false
}
MoveAndFollow(workspace) {
    Komorebic("move-to-workspace " workspace)
    FocusWorkspace(workspace)
}

FocusWorkspace(workspace) {
    Komorebic("focus-workspace " workspace)
    ScheduleWorkspaceOneLayoutGuard()
}

CycleWorkspace(direction) {
    Komorebic("cycle-workspace " direction)
    ScheduleWorkspaceOneLayoutGuard()
}

ScheduleWorkspaceOneLayoutGuard() {
    ; Chromium/Edge can publish a second restore/activation event after the
    ; workspace switch animation. Recheck through that short restore window.
    SetTimer(GuardWorkspaceOneLayout, -250)
    SetTimer(GuardWorkspaceOneLayoutSecondPass, -750)
    SetTimer(GuardWorkspaceOneLayoutFinalPass, -1500)
}

GuardWorkspaceOneLayoutSecondPass() {
    GuardWorkspaceOneLayout()
}

GuardWorkspaceOneLayoutFinalPass() {
    GuardWorkspaceOneLayout()
}

GuardWorkspaceOneLayout() {
    global ExplicitWorkspaceOneMonocle
    try {
        state := JsonParse(CaptureKomorebiJson("state"))
        monitors := state["monitors"]
        monitor := monitors["elements"][monitors["focused"] + 1]
        workspaces := monitor["workspaces"]
        if workspaces["focused"] != 0
            return
        workspace := workspaces["elements"][1]
        if workspace["layout"]["Default"] != "Grid"
            Komorebic("change-layout grid")
        if workspace["monocle_container"] is Map && !ExplicitWorkspaceOneMonocle {
            Komorebic("toggle-monocle")
            ; Verify once more after Komorebi and Edge finish repainting.
            SetTimer(GuardWorkspaceOneLayoutFinalPass, -500)
        }
    }
}

LaunchWezTermWindow() {
    global WezTermGuiExe
    Run('"' WezTermGuiExe '" start --always-new-process')
}

PrewarmDropdownApps() {
    ToggleDropdownTerminal(true)
    ToggleDropdownApp("explorer", true)
    ToggleDropdownApp("notepad", true)
}

ToggleDropdownTerminal(prewarm := false) {
    global DropdownTitle, WezTermGuiExe

    ; The custom class keeps this drop-down separate from ordinary WezTerm
    ; windows, even though both run the same executable.
    terminalSelector := "ahk_class KomorebiDropdown ahk_exe wezterm-gui.exe"

    previousDetectHidden := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := FindDropdownWindow()
    previousActiveHwnd := prewarm ? WinExist("A") : 0
    if !prewarm && (!hwnd || !DllCall("IsWindowVisible", "Ptr", hwnd))
        RememberFocusBeforeDropdown("terminal", hwnd)

    ; A script reload must not hide or otherwise disturb a dropdown that the
    ; user already has open.
    if prewarm && hwnd {
        DetectHiddenWindows(previousDetectHidden)
        return
    }

    if !hwnd {
        existingWindows := Map()
        for existingHwnd in WinGetList(terminalSelector)
            existingWindows[existingHwnd] := true

        ; Start hidden; AnimateDropdown performs the first visible reveal only
        ; after the terminal surface has initialized and been positioned.
        Run('"' WezTermGuiExe '" start --always-new-process --class KomorebiDropdown', , "Hide")
        hwnd := WaitForNewWindow(terminalSelector, existingWindows, 8000, 40)
        if !hwnd {
            DetectHiddenWindows(previousDetectHidden)
            TrayTip("WezTerm did not appear.", "Dropdown terminal", 2)
            return
        }
        DllCall("User32\SetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownTerminal", "Ptr", 1)
        WinSetTitle(DropdownTitle, "ahk_id " hwnd)
        ; Keep the first frame off-screen while its final geometry is prepared.
        WinHide("ahk_id " hwnd)
    } else if DllCall("IsWindowVisible", "Ptr", hwnd) {
        AnimateDropdown(hwnd, false)
        QueueFocusRestoreAfterDropdown("terminal", hwnd)
        DetectHiddenWindows(previousDetectHidden)
        return
    }

    if !IsLiveWindow(hwnd) {
        DetectHiddenWindows(previousDetectHidden)
        TrayTip("The terminal window was recreated; press the hotkey again.", "Dropdown terminal", 2)
        return
    }
    if !EnsureDropdownFloating(hwnd, prewarm) {
        DetectHiddenWindows(previousDetectHidden)
        TrayTip("The dropdown could not be moved to Komorebi's floating layer.", "Dropdown terminal", 2)
        return
    }
    if prewarm {
        try PositionDropdownWindow(hwnd)
        if previousActiveHwnd && WinExist("ahk_id " previousActiveHwnd)
            WinActivate("ahk_id " previousActiveHwnd)
        DetectHiddenWindows(previousDetectHidden)
        return
    }
    try {
        PositionDropdownWindow(hwnd)
        WinSetAlwaysOnTop(true, "ahk_id " hwnd)
        AnimateDropdown(hwnd, true)
    } catch {
        TrayTip("The terminal window changed while opening; please try again.", "Dropdown terminal", 2)
    }
    DetectHiddenWindows(previousDetectHidden)
}

PositionDropdownWindow(hwnd) {
    GetDropdownRect(&targetX, &targetY, &targetW, &targetH)
    WinMove(targetX, targetY, targetW, targetH, "ahk_id " hwnd)
}

EnsureDropdownFloating(hwnd, prepareHidden := false) {
    ; This HWND property survives AHK reloads and prevents a later toggle from
    ; accidentally returning an already-floating dropdown to the tiled layer.
    if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownFloated", "Ptr")
        return true

    emptyRegion := 0
    if prepareHidden {
        ; The window must briefly enter the interactive desktop so Komorebi can
        ; put it on the floating layer. An empty region makes that setup frame
        ; fully invisible.
        emptyRegion := DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", 0, "Int", 0, "Ptr")
        if emptyRegion
            DllCall("User32\SetWindowRgn", "Ptr", hwnd, "Ptr", emptyRegion, "Int", true)
    }

    WinShow("ahk_id " hwnd)
    WinActivate("ahk_id " hwnd)
    if !WinWaitActive("ahk_id " hwnd, , 1) {
        WinHide("ahk_id " hwnd)
        if emptyRegion
            DllCall("User32\SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", true)
        return false
    }

    ; Allow Komorebi to register a freshly shown WezTerm HWND, then float only
    ; the focused dropdown—not every ordinary wezterm-gui.exe window.
    Sleep(40)
    Komorebic("toggle-float")
    Sleep(40)
    DllCall("User32\SetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownFloated", "Ptr", 1)
    WinHide("ahk_id " hwnd)
    if emptyRegion
        DllCall("User32\SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", true)
    return true
}

FindDropdownWindow() {
    global DropdownTitle
    selector := "ahk_class KomorebiDropdown ahk_exe wezterm-gui.exe"
    for hwnd in WinGetList(selector) {
        if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownTerminal", "Ptr")
            return hwnd
        ; The title is retained as a fallback recovery key.
        if WinGetTitle("ahk_id " hwnd) = DropdownTitle {
            DllCall("User32\SetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownTerminal", "Ptr", 1)
            return hwnd
        }
    }
    return 0
}

WaitForNewWindow(selector, existingWindows, timeoutMs, settleMs := 400, pollMs := 40) {
    deadline := A_TickCount + timeoutMs
    candidateSince := Map()
    while A_TickCount < deadline {
        for hwnd in WinGetList(selector) {
            if !existingWindows.Has(hwnd) {
                if !candidateSince.Has(hwnd)
                    candidateSince[hwnd] := A_TickCount
                else if A_TickCount - candidateSince[hwnd] >= settleMs && IsLiveWindow(hwnd)
                    return hwnd
            }
        }
        Sleep(pollMs)
    }
    return 0
}

IsLiveWindow(hwnd) {
    return hwnd && DllCall("User32\IsWindow", "Ptr", hwnd, "Int")
}

RememberFocusBeforeDropdown(dropdownKey, dropdownHwnd) {
    global DropdownReturnFocus
    activeHwnd := WinExist("A")
    if IsValidDropdownReturnWindow(activeHwnd, dropdownHwnd)
        DropdownReturnFocus[dropdownKey] := activeHwnd
}

QueueFocusRestoreAfterDropdown(dropdownKey, dropdownHwnd) {
    ; Poll briefly instead of blocking inside KeyWait. A blocked timer can wake
    ; after the user has already clicked another normal window and steal focus
    ; back from that click.
    SetTimer(RestoreFocusAfterDropdown.Bind(dropdownKey, dropdownHwnd, A_TickCount), -15)
}

RestoreFocusAfterDropdown(dropdownKey, dropdownHwnd, queuedAt) {
    global DropdownReturnFocus
    targetHwnd := DropdownReturnFocus.Has(dropdownKey) ? DropdownReturnFocus[dropdownKey] : 0

    ; A real click always wins. Never let delayed shortcut cleanup take focus
    ; away from a window the user has deliberately selected.
    if GetKeyState("LButton", "P") || GetKeyState("RButton", "P") || GetKeyState("MButton", "P") {
        if DropdownReturnFocus.Has(dropdownKey)
            DropdownReturnFocus.Delete(dropdownKey)
        return
    }

    ; Wait asynchronously for the dropdown shortcut modifier to be released,
    ; but abandon stale restores instead of activating a window much later.
    if GetKeyState("Shift", "P") || IsMainModifierPressed() {
        if A_TickCount - queuedAt < 750
            SetTimer(RestoreFocusAfterDropdown.Bind(dropdownKey, dropdownHwnd, queuedAt), -15)
        else if DropdownReturnFocus.Has(dropdownKey)
            DropdownReturnFocus.Delete(dropdownKey)
        return
    }

    if IsValidDropdownReturnWindow(targetHwnd, dropdownHwnd) {
        try {
            WinActivate("ahk_id " targetHwnd)
            WinWaitActive("ahk_id " targetHwnd, , 0.35)
        }
    }
    ; The saved HWND is single-use. Do not issue a broad fallback focus command
    ; that could override the user's next deliberate click.
    if DropdownReturnFocus.Has(dropdownKey)
        DropdownReturnFocus.Delete(dropdownKey)
}

IsValidDropdownReturnWindow(hwnd, dropdownHwnd := 0) {
    if !IsLiveWindow(hwnd) || hwnd = dropdownHwnd
        return false
    if !DllCall("User32\IsWindowVisible", "Ptr", hwnd, "Int")
        return false
    if DllCall("User32\IsIconic", "Ptr", hwnd, "Int")
        return false
    if IsDropdownWindow(hwnd)
        return false

    try {
        className := WinGetClass("ahk_id " hwnd)
        return className != "Progman"
            && className != "WorkerW"
            && className != "Shell_TrayWnd"
            && className != "Shell_SecondaryTrayWnd"
    } catch {
        return false
    }
}

IsDropdownWindow(hwnd) {
    if !IsLiveWindow(hwnd)
        return false
    if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownTerminal", "Ptr")
        return true
    if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownExplorer", "Ptr")
        return true
    if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", "KomorebiDropdownNotepad", "Ptr")
        return true
    try return WinGetClass("ahk_id " hwnd) = "KomorebiDropdown"
    catch
        return false
}


ToggleDropdownApp(appName, prewarm := false) {
    global DropdownNotesFile
    if appName = "explorer" {
        marker := "KomorebiDropdownExplorer"
        dropdownWindowTitle := "Komorebi Dropdown Explorer"
        selector := "ahk_class CabinetWClass ahk_exe explorer.exe"
        launchCommand := "explorer.exe"
        newWindowShortcut := "^n"
        failureMessage := "A separate File Explorer window was not created."
    } else {
        marker := "KomorebiDropdownNotepad"
        dropdownWindowTitle := "Komorebi Dropdown Notepad"
        ; Modern Notepad exposes several helper HWNDs under Notepad.exe. Match
        ; only its real top-level editor window so reboot-time detection is stable.
        selector := "ahk_class Notepad ahk_exe Notepad.exe"
        launchCommand := 'notepad.exe "' DropdownNotesFile '"'
        newWindowShortcut := "^+n"
        failureMessage := "A separate Notepad window was not created."
    }

    previousDetectHidden := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := FindMarkedDropdownWindow(marker, selector, dropdownWindowTitle)
    if !prewarm && (!hwnd || !DllCall("IsWindowVisible", "Ptr", hwnd))
        RememberFocusBeforeDropdown(appName, hwnd)

    ; Preserve a currently open dropdown when AutoHotkey is reloaded.
    if prewarm && hwnd {
        DetectHiddenWindows(previousDetectHidden)
        return
    }

    if !hwnd {
        existingWindows := Map()
        for existingHwnd in WinGetList(selector)
            existingWindows[existingHwnd] := true

        previousActiveHwnd := WinExist("A")
        sourceHwnd := 0
        for existingHwnd, _ in existingWindows {
            sourceHwnd := existingHwnd
            break
        }

        if sourceHwnd && appName = "explorer" && !prewarm {
            ; Both applications expose a native new-window shortcut. This asks
            ; the app for a distinct top-level HWND without changing its content.
            WinActivate("ahk_id " sourceHwnd)
            if WinWaitActive("ahk_id " sourceHwnd, , 2)
                Send(newWindowShortcut)
        } else {
            Run(launchCommand, , prewarm ? "Hide" : "")
        }

        hwnd := WaitForNewWindow(selector, existingWindows, 8000, prewarm ? 0 : 400, prewarm ? 10 : 40)
        if previousActiveHwnd && WinExist("ahk_id " previousActiveHwnd)
            WinActivate("ahk_id " previousActiveHwnd)
        if !hwnd {
            DetectHiddenWindows(previousDetectHidden)
            TrayTip(failureMessage " Existing windows were left untouched.", "Dropdown " appName, 3)
            return
        }

        DllCall("User32\SetPropW", "Ptr", hwnd, "Str", marker, "Ptr", 1)
        WinSetTitle(dropdownWindowTitle, "ahk_id " hwnd)

        emptyRegion := 0
        if prewarm {
            ; Explorer is brokered by the existing shell process and modern
            ; Notepad may ignore SW_HIDE. Remove the native window region before
            ; showing it for Komorebi's one-time floating-layer registration.
            emptyRegion := DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", 0, "Int", 0, "Ptr")
            if emptyRegion
                DllCall("User32\SetWindowRgn", "Ptr", hwnd, "Ptr", emptyRegion, "Int", true)
            WinShow("ahk_id " hwnd)
        }

        ; Float only the newly-created window. No title/executable-wide session
        ; rule is added, so ordinary Explorer and Notepad windows stay normal.
        WinActivate("ahk_id " hwnd)
        if WinWaitActive("ahk_id " hwnd, , 2) {
            Komorebic("toggle-float")
            Sleep(100)
        }
        ; Match the terminal path: keep the first frame hidden until its final
        ; size and native slide-down animation are ready.
        WinHide("ahk_id " hwnd)
        if emptyRegion
            DllCall("User32\SetWindowRgn", "Ptr", hwnd, "Ptr", 0, "Int", true)
        if prewarm {
            try {
                GetDropdownRect(&targetX, &targetY, &targetW, &targetH)
                WinMove(targetX, targetY, targetW, targetH, "ahk_id " hwnd)
            }
            if previousActiveHwnd && WinExist("ahk_id " previousActiveHwnd)
                WinActivate("ahk_id " previousActiveHwnd)
            DetectHiddenWindows(previousDetectHidden)
            return
        }
    } else if DllCall("IsWindowVisible", "Ptr", hwnd) {
        ; Identical close behavior to the PowerShell dropdown.
        AnimateDropdown(hwnd, false)
        QueueFocusRestoreAfterDropdown(appName, hwnd)
        DetectHiddenWindows(previousDetectHidden)
        return
    }

    ; Hidden XAML windows may retain WS_MAXIMIZE. Clear it before Komorebi
    ; observes the reveal, and present the unique title used by its float rule.
    if !IsLiveWindow(hwnd) {
        DetectHiddenWindows(previousDetectHidden)
        TrayTip("The app window was recreated; press the hotkey again.", "Dropdown " appName, 2)
        return
    }
    try {
        WinSetTitle(dropdownWindowTitle, "ahk_id " hwnd)
        if WinGetMinMax("ahk_id " hwnd) = 1
            WinRestore("ahk_id " hwnd)
        GetDropdownRect(&targetX, &targetY, &targetW, &targetH)
        WinMove(targetX, targetY, targetW, targetH, "ahk_id " hwnd)
        WinSetAlwaysOnTop(true, "ahk_id " hwnd)
        AnimateDropdown(hwnd, true)
    } catch {
        TrayTip("The app window changed while opening; please try again.", "Dropdown " appName, 2)
    }
    DetectHiddenWindows(previousDetectHidden)
}

FindMarkedDropdownWindow(marker, selector, dropdownWindowTitle) {
    for hwnd in WinGetList(selector) {
        if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", marker, "Ptr")
            return hwnd
        if WinGetTitle("ahk_id " hwnd) = dropdownWindowTitle {
            DllCall("User32\SetPropW", "Ptr", hwnd, "Str", marker, "Ptr", 1)
            return hwnd
        }
    }
    return 0
}

GetDropdownRect(&x, &y, &width, &height) {
    MouseGetPos(&mouseX, &mouseY)
    monitorIndex := 1
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        if mouseX >= left && mouseX < right && mouseY >= top && mouseY < bottom {
            monitorIndex := A_Index
            break
        }
    }

    MonitorGetWorkArea(monitorIndex, &left, &top, &right, &bottom)
    monitorWidth := right - left
    monitorHeight := bottom - top
    width := Round(monitorWidth * 0.75)
    height := Round(monitorHeight * 0.75)
    x := left + Round((monitorWidth - width) / 2)
    y := top + Round((monitorHeight - height) / 2)
}

AnimateDropdown(hwnd, showing) {
    ; Let DWM animate a single already-sized surface. Unlike repeated WinMove
    ; calls, this does not force every tiled window and the game to redraw.
    AW_SLIDE := 0x00040000
    if showing {
        AW_ACTIVATE := 0x00020000
        AW_VER_POSITIVE := 0x00000004
        if !DllCall("User32\AnimateWindow", "Ptr", hwnd, "UInt", 170, "UInt", AW_SLIDE | AW_ACTIVATE | AW_VER_POSITIVE)
            WinShow("ahk_id " hwnd)
        WinActivate("ahk_id " hwnd)
    } else {
        AW_HIDE := 0x00010000
        AW_VER_NEGATIVE := 0x00000008
        if !DllCall("User32\AnimateWindow", "Ptr", hwnd, "UInt", 140, "UInt", AW_SLIDE | AW_HIDE | AW_VER_NEGATIVE)
            WinHide("ahk_id " hwnd)
    }
}

ToggleMonocle() {
    global ExplicitWorkspaceOneMonocle
    ; A window left in native-maximized state fights Komorebi's monocle sizing.
    ; Restore it first so fake fullscreen keeps the configured gaps and corners.
    if WinGetMinMax("A") = 1 {
        Komorebic("toggle-maximize")
        Sleep(150)
    }
    try {
        state := JsonParse(CaptureKomorebiJson("state"))
        monitors := state["monitors"]
        monitor := monitors["elements"][monitors["focused"] + 1]
        workspaces := monitor["workspaces"]
        if workspaces["focused"] = 0
            ExplicitWorkspaceOneMonocle := !(workspaces["elements"][1]["monocle_container"] is Map)
    }
    Komorebic("toggle-monocle")
}

InitializeWindowGlass() {
    global ShellHookMessage

    ; Komorebi transparency is disabled so it never resets a freshly focused
    ; window to opaque. Apply one constant glass alpha on shell create/focus.
    ShellHookMessage := DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt")
    if ShellHookMessage {
        DllCall("RegisterShellHookWindow", "Ptr", A_ScriptHwnd)
        OnMessage(ShellHookMessage, HandleShellWindowEvent)
    }
    KeepAllWindowsTranslucent()
}

HandleShellWindowEvent(eventCode, hwnd, *) {
    ; HSHELL_WINDOWCREATED, HSHELL_WINDOWACTIVATED, HSHELL_RUDEAPPACTIVATED.
    if eventCode = 1 || eventCode = 4 || eventCode = 0x8004 {
        KeepWindowTranslucent(hwnd)
        ; Some apps finish creating their native window just after the shell event.
        SetTimer(KeepWindowTranslucent.Bind(hwnd), -1)
    }
    ; Workspace changes also surface as shell activation events, including YASB.
    if eventCode = 4 || eventCode = 0x8004
        ScheduleWorkspaceOneLayoutGuard()
}

KeepAllWindowsTranslucent() {
    for hwnd in WinGetList()
        KeepWindowTranslucent(hwnd)
}

KeepWindowTranslucent(hwnd) {
    global FocusedWindowAlpha

    if !hwnd || !WinExist("ahk_id " hwnd)
        return

    try {
        style := WinGetStyle("ahk_id " hwnd)
        if !(style & 0x10000000) || WinGetMinMax("ahk_id " hwnd) = -1
            return

        className := WinGetClass("ahk_id " hwnd)
        if className = "Progman" || className = "WorkerW" || className = "Shell_TrayWnd" || className = "Shell_SecondaryTrayWnd"
            return

        processName := StrLower(WinGetProcessName("ahk_id " hwnd))
        if processName = "yasb.exe" || processName = "komorebi.exe" || processName = "autohotkey64.exe"
            return
        if processName = "brave.exe" || processName = "chrome.exe" || processName = "msedge.exe" {
            RestoreNativeBrowserWindow(hwnd)
            return
        }

        ; DWMBlurGlass restores the legacy blur-behind API on Windows 11.
        ; Request a full-window blur region once for every normal app HWND,
        ; then retain the constant alpha so the Acrylic surface is visible.
        EnableFullWindowDwmBlur(hwnd)

        ; Reapplying WS_EX_LAYERED on every activation makes Chromium windows
        ; visibly repaint when returning to their workspace.
        if WinGetTransparent("ahk_id " hwnd) != FocusedWindowAlpha
            WinSetTransparent(FocusedWindowAlpha, "ahk_id " hwnd)
    }
}

RestoreNativeBrowserWindow(hwnd) {
    static BlurProperty := "KomorebiFullWindowDwmBlur"

    ; Browsers keep their native frame; AHK must not add a layered/translucent
    ; style that changes the dimensions Komorebi measures during startup.
    if WinGetTransparent("ahk_id " hwnd) != ""
        WinSetTransparent("Off", "ahk_id " hwnd)

    blurBehind := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 0x1, blurBehind, 0) ; DWM_BB_ENABLE
    NumPut("Int", 0, blurBehind, 4)
    DllCall("Dwmapi\DwmEnableBlurBehindWindow", "Ptr", hwnd, "Ptr", blurBehind, "Int")
    DllCall("User32\RemovePropW", "Ptr", hwnd, "Str", BlurProperty, "Ptr")
}

EnableFullWindowDwmBlur(hwnd) {
    static BlurProperty := "KomorebiFullWindowDwmBlur"

    if DllCall("User32\GetPropW", "Ptr", hwnd, "Str", BlurProperty, "Ptr")
        return

    ; DWM_BLURBEHIND: dwFlags, fEnable, hRgnBlur, fTransitionOnMaximized.
    blurRegion := DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", -1, "Int", -1, "Ptr")
    if !blurRegion
        return

    blurBehind := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 0x3, blurBehind, 0) ; DWM_BB_ENABLE | DWM_BB_BLURREGION
    NumPut("Int", 1, blurBehind, 4)
    NumPut("Ptr", blurRegion, blurBehind, 8)

    result := DllCall("Dwmapi\DwmEnableBlurBehindWindow", "Ptr", hwnd, "Ptr", blurBehind, "Int")
    DllCall("Gdi32\DeleteObject", "Ptr", blurRegion)
    if result = 0
        DllCall("User32\SetPropW", "Ptr", hwnd, "Str", BlurProperty, "Ptr", 1)
}

HideWindowsTaskbars() {
    global WindowsTaskbarHidden
    if !WindowsTaskbarHidden
        return

    previousSetting := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    for className in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"] {
        for hwnd in WinGetList("ahk_class " className)
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
    }
    DetectHiddenWindows(previousSetting)
}

ApplyKomorebiWorkArea() {
    global WindowsTaskbarHidden

    ; Komorebi sizes against Windows' work area, which still excludes taskbars
    ; hidden with ShowWindow. Match taskbars to Komorebi's physical monitor
    ; rectangles and reclaim the reserved edge at its actual DPI-scaled size.
    try {
        state := JsonParse(CaptureKomorebiJson("state"))
        monitors := state["monitors"]["elements"]
        taskbars := []

        if WindowsTaskbarHidden {
            previousSetting := A_DetectHiddenWindows
            DetectHiddenWindows(true)
            try {
                for className in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"] {
                    for hwnd in WinGetList("ahk_class " className) {
                        WinGetPos(&x, &y, &width, &height, "ahk_id " hwnd)
                        if width > 0 && height > 0
                            taskbars.Push(Map("x", x, "y", y, "width", width, "height", height))
                    }
                }
            } finally {
                DetectHiddenWindows(previousSetting)
            }
        }

        for monitorIndex, monitor in monitors {
            size := monitor["size"]
            monitorLeft := size["left"]
            monitorTop := size["top"]
            monitorRight := monitorLeft + size["right"]
            monitorBottom := monitorTop + size["bottom"]
            ; Account for Komorebi's frame geometry so tiled windows align
            ; with YASB's approximately 8 px outer edge on every monitor.
            left := 4
            top := -1
            right := 8
            bottom := 1

            for taskbar in taskbars {
                centerX := taskbar["x"] + (taskbar["width"] / 2)
                centerY := taskbar["y"] + (taskbar["height"] / 2)
                if centerX < monitorLeft || centerX >= monitorRight
                    || centerY < monitorTop || centerY >= monitorBottom
                    continue

                if taskbar["width"] >= taskbar["height"] {
                    if centerY < monitorTop + ((monitorBottom - monitorTop) / 2) {
                        top -= taskbar["height"]
                        bottom -= taskbar["height"]
                    } else {
                        bottom -= taskbar["height"]
                    }
                } else if centerX < monitorLeft + ((monitorRight - monitorLeft) / 2) {
                    left -= taskbar["width"]
                    right -= taskbar["width"]
                } else {
                    right -= taskbar["width"]
                }
            }

            Komorebic("monitor-work-area-offset " (monitorIndex - 1) " -- " left " " top " " right " " bottom)
        }
        Komorebic("retile", false)
    }
}

ToggleWindowsTaskbars() {
    global WindowsTaskbarHidden
    WindowsTaskbarHidden := !WindowsTaskbarHidden

    previousSetting := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    for className in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"] {
        for hwnd in WinGetList("ahk_class " className)
            DllCall("ShowWindow", "Ptr", hwnd, "Int", WindowsTaskbarHidden ? 0 : 5)
    }
    DetectHiddenWindows(previousSetting)
    ApplyKomorebiWorkArea()

    TrayTip(WindowsTaskbarHidden ? "Native taskbar fully hidden." : "Native taskbar restored.", "Windows Taskbar", 1)
}

ToggleYasbQuickLaunch() {
    ; YASB 2.0.6 has no CLI command for widget callbacks. Forward this unused
    ; chord to Quick Launch's native global keybinding for reliable toggling.
    SendEvent("^!+{F10}")

    ; Center asynchronously so this hotkey returns immediately and every rapid
    ; modifier+D press can toggle the popup without waiting for layout settling.
    global QuickLaunchCenterAttempts := 0
    SetTimer(CenterYasbQuickLaunch, 30)
}

CenterYasbQuickLaunch() {
    global QuickLaunchCenterAttempts
    QuickLaunchCenterAttempts += 1
    if QuickLaunchCenterAttempts > 20 {
        SetTimer(CenterYasbQuickLaunch, 0)
        return
    }

    try {
        if StrLower(WinGetProcessName("A")) != "yasb.exe"
            return

        popupHwnd := WinExist("A")
        WinGetPos(&popupX, &popupY, &popupWidth, &popupHeight, "ahk_id " popupHwnd)
        if popupWidth < 300 || popupHeight < 300
            return

        popupCenterX := popupX + Floor(popupWidth / 2)
        popupCenterY := popupY + Floor(popupHeight / 2)
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &workLeft, &workTop, &workRight, &workBottom)
            if popupCenterX < workLeft || popupCenterX >= workRight
                continue
            if popupCenterY < workTop || popupCenterY >= workBottom
                continue

            centeredX := workLeft + Floor((workRight - workLeft - popupWidth) / 2)
            centeredY := workTop + Floor((workBottom - workTop - popupHeight) / 2)
            WinMove(centeredX, centeredY, , , "ahk_id " popupHwnd)
            SetTimer(CenterYasbQuickLaunch, 0)
            return
        }
    }
}

IsMainModifierPressed() {
    global MainModifier
    if MainModifier = "Win"
        return GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
    return GetKeyState("F13", "P") || GetKeyState("CapsLock", "P")
}

CaptureKomorebiJson(command) {
    global KomorebicExe
    shell := ComObject("WScript.Shell")
    process := shell.Exec('"' KomorebicExe '" ' command)
    output := process.StdOut.ReadAll()
    if process.ExitCode != 0 || !Trim(output)
        throw Error("Komorebi state query failed")
    return output
}

RefreshManagedWindowCache(*) {
    global ManagedWindowRoles, ManagedWorkspaceSnapshot, LastManagedStateRefresh
    roles := Map()
    snapshot := Map("tiles", [], "supported", false)

    try {
        state := JsonParse(CaptureKomorebiJson("state"))
        monitors := state["monitors"]
        monitor := monitors["elements"][monitors["focused"] + 1]
        workspaces := monitor["workspaces"]
        workspace := workspaces["elements"][workspaces["focused"] + 1]
        layout := workspace["layout"]
        isGrid := layout is Map && layout.Has("Default") && layout["Default"] = "Grid"
        hasMonocle := workspace["monocle_container"] is Map
        hasMaximized := workspace["maximized_window"] is Map
        snapshot["supported"] := isGrid && !hasMonocle && !hasMaximized

        for container in workspace["containers"]["elements"] {
            windows := container["windows"]["elements"]
            role := snapshot["supported"] && windows.Length = 1 ? "Tiled" : "TiledUnsupported"
            for window in windows {
                hwnd := window["hwnd"]
                roles[hwnd] := role
                if role = "Tiled" {
                    rect := window["rect"]
                    snapshot["tiles"].Push(Map(
                        "hwnd", hwnd,
                        "left", rect["left"],
                        "top", rect["top"],
                        "width", rect["right"],
                        "height", rect["bottom"]
                    ))
                }
            }
        }

        floating := workspace["floating_windows"]["elements"]
        for window in floating
            roles[window["hwnd"]] := IsDropdownWindow(window["hwnd"]) ? "Dropdown" : "Floating"
    } catch {
        ; Fail open: an offline or inaccessible Komorebi socket must never make
        ; ordinary Windows input unusable based on stale management data.
        roles := Map()
        snapshot := Map("tiles", [], "supported", false)
    }

    ManagedWindowRoles := roles
    ManagedWorkspaceSnapshot := snapshot
    LastManagedStateRefresh := A_TickCount
    return roles.Count > 0
}

GetManagedWindowRole(hwnd) {
    global ManagedWindowRoles, LastManagedStateRefresh
    if IsDropdownWindow(hwnd)
        return "Dropdown"
    if A_TickCount - LastManagedStateRefresh > 900
        RefreshManagedWindowCache()
    return ManagedWindowRoles.Has(hwnd) ? ManagedWindowRoles[hwnd] : "Unmanaged"
}

GetWindowHitTest(hwnd, screenX, screenY) {
    packedPoint := ((screenY & 0xFFFF) << 16) | (screenX & 0xFFFF)
    try return SendMessage(0x84, 0, packedPoint, , "ahk_id " hwnd) ; WM_NCHITTEST
    catch
        return 0
}

ShouldHandleManagedLeftButton() {
    MouseGetPos(&mouseX, &mouseY, &hwnd)
    role := GetManagedWindowRole(hwnd)
    if role = "Unmanaged"
        return false
    if IsMainModifierPressed()
        return true
    return GetWindowHitTest(hwnd, mouseX, mouseY) = 2 ; HTCAPTION only
}

HandleManagedLeftButton() {
    MouseGetPos(&mouseX, &mouseY, &hwnd)
    role := GetManagedWindowRole(hwnd)
    if role = "Unmanaged"
        return

    try WinActivate("ahk_id " hwnd)
    if !IsMainModifierPressed() {
        BlockManagedTitlebarDrag(hwnd)
        return
    }

    if role = "Floating" || role = "Dropdown" {
        ; Ask Windows to enter its native move loop. Because this is invoked
        ; only from the modifier gesture, ordinary titlebar movement stays off.
        DllCall("User32\ReleaseCapture")
        PostMessage(0xA1, 2, 0, , "ahk_id " hwnd) ; WM_NCLBUTTONDOWN, HTCAPTION
        return
    }

    if role = "Tiled"
        DragTiledWindow(hwnd, mouseX, mouseY)
}

BlockManagedTitlebarDrag(hwnd) {
    global LastBlockedTitleClickHwnd, LastBlockedTitleClickAt
    now := A_TickCount
    isDoubleClick := hwnd = LastBlockedTitleClickHwnd
        && now - LastBlockedTitleClickAt <= DllCall("User32\GetDoubleClickTime", "UInt")
    LastBlockedTitleClickHwnd := hwnd
    LastBlockedTitleClickAt := now
    if isDoubleClick {
        PostMessage(0xA3, 2, 0, , "ahk_id " hwnd) ; WM_NCLBUTTONDBLCLK
        LastBlockedTitleClickAt := 0
    }
}

DragTiledWindow(hwnd, startMouseX, startMouseY) {
    global ManagedWorkspaceSnapshot
    if !ManagedWorkspaceSnapshot.Has("supported") || !ManagedWorkspaceSnapshot["supported"]
        return

    try WinGetPos(&windowX, &windowY, &windowW, &windowH, "ahk_id " hwnd)
    catch
        return

    offsetX := startMouseX - windowX
    offsetY := startMouseY - windowY
    preview := CreateDragPreview(hwnd, windowX, windowY, windowW, windowH)
    lastTarget := 0
    lastMoveAt := 0
    animationEnabled := false

    try {
        EnableDragAnimation()
        animationEnabled := true
        while GetKeyState("LButton", "P") && IsMainModifierPressed() && IsLiveWindow(hwnd) {
            MouseGetPos(&mouseX, &mouseY)
            MoveDragPreview(preview, mouseX - offsetX, mouseY - offsetY)
            target := FindTileAtPoint(mouseX, mouseY, hwnd)
            if target && target["hwnd"] != lastTarget && A_TickCount - lastMoveAt >= 180 {
                source := FindTileByHwnd(hwnd)
                if source {
                    direction := GetTileDirection(source, target)
                    if direction {
                        try WinActivate("ahk_id " hwnd)
                        Komorebic("move " direction)
                        lastTarget := target["hwnd"]
                        lastMoveAt := A_TickCount
                        RefreshManagedWindowCache()
                    }
                }
            }
            Sleep(16)
        }
    } finally {
        DestroyDragPreview(preview)
        if animationEnabled
            DisableDragAnimation()
        RefreshManagedWindowCache()
    }
}

EnableDragAnimation() {
    Komorebic("animation-duration --animation-type movement 180")
    Komorebic("animation-fps 60")
    Komorebic("animation-style --animation-type movement --style ease-out-sine")
    Komorebic("animation --animation-type movement enable")
}

DisableDragAnimation() {
    ; Keep ordinary tiling instantaneous; animation is used only while dragging.
    Komorebic("animation --animation-type movement disable", false)
}

FindTileByHwnd(hwnd) {
    global ManagedWorkspaceSnapshot
    for tile in ManagedWorkspaceSnapshot["tiles"] {
        if tile["hwnd"] = hwnd
            return tile
    }
    return 0
}

FindTileAtPoint(x, y, sourceHwnd) {
    global ManagedWorkspaceSnapshot
    for tile in ManagedWorkspaceSnapshot["tiles"] {
        if tile["hwnd"] = sourceHwnd
            continue
        margin := Min(16, Floor(Min(tile["width"], tile["height"]) / 4))
        if x >= tile["left"] + margin && x < tile["left"] + tile["width"] - margin
            && y >= tile["top"] + margin && y < tile["top"] + tile["height"] - margin
            return tile
    }
    return 0
}

GetTileDirection(source, target) {
    sourceX := source["left"] + source["width"] / 2
    sourceY := source["top"] + source["height"] / 2
    targetX := target["left"] + target["width"] / 2
    targetY := target["top"] + target["height"] / 2
    deltaX := targetX - sourceX
    deltaY := targetY - sourceY
    if Abs(deltaX) >= Abs(deltaY)
        return deltaX < 0 ? "left" : "right"
    return deltaY < 0 ? "up" : "down"
}

CreateDragPreview(sourceHwnd, x, y, width, height) {
    previewGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000")
    previewGui.BackColor := "081423"
    previewGui.Show("NA x" x " y" y " w" width " h" height)
    thumbnail := 0
    if DllCall("Dwmapi\DwmRegisterThumbnail", "Ptr", previewGui.Hwnd, "Ptr", sourceHwnd, "Ptr*", &thumbnail) = 0 {
        properties := Buffer(48, 0)
        NumPut("UInt", 0x01 | 0x04 | 0x08, properties, 0) ; destination, opacity, visible
        NumPut("Int", 0, "Int", 0, "Int", width, "Int", height, properties, 4)
        NumPut("UChar", 190, properties, 36)
        NumPut("Int", 1, properties, 40)
        DllCall("Dwmapi\DwmUpdateThumbnailProperties", "Ptr", thumbnail, "Ptr", properties)
    } else
        WinSetTransparent(100, "ahk_id " previewGui.Hwnd)
    return Map("gui", previewGui, "thumbnail", thumbnail, "width", width, "height", height)
}

MoveDragPreview(preview, x, y) {
    try preview["gui"].Show("NA x" Round(x) " y" Round(y)
        " w" preview["width"] " h" preview["height"])
}

DestroyDragPreview(preview) {
    if !preview
        return
    if preview["thumbnail"]
        DllCall("Dwmapi\DwmUnregisterThumbnail", "Ptr", preview["thumbnail"])
    try preview["gui"].Destroy()
}

JsonParse(text) {
    position := 1
    value := JsonParseValue(text, &position)
    JsonSkipWhitespace(text, &position)
    if position <= StrLen(text)
        throw Error("Unexpected JSON content at " position)
    return value
}

JsonParseValue(text, &position) {
    JsonSkipWhitespace(text, &position)
    token := SubStr(text, position, 1)
    if token = "{"
        return JsonParseObject(text, &position)
    if token = "["
        return JsonParseArray(text, &position)
    if token = '"'
        return JsonParseString(text, &position)
    if SubStr(text, position, 4) = "true" {
        position += 4
        return true
    }
    if SubStr(text, position, 5) = "false" {
        position += 5
        return false
    }
    if SubStr(text, position, 4) = "null" {
        position += 4
        return ""
    }
    if RegExMatch(SubStr(text, position), "^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?", &number) {
        position += StrLen(number[0])
        return number[0] + 0
    }
    throw Error("Invalid JSON value at " position)
}

JsonParseObject(text, &position) {
    object := Map()
    position += 1
    JsonSkipWhitespace(text, &position)
    if SubStr(text, position, 1) = "}" {
        position += 1
        return object
    }
    loop {
        key := JsonParseString(text, &position)
        JsonSkipWhitespace(text, &position)
        if SubStr(text, position, 1) != ":"
            throw Error("Expected JSON colon at " position)
        position += 1
        object[key] := JsonParseValue(text, &position)
        JsonSkipWhitespace(text, &position)
        token := SubStr(text, position, 1)
        position += 1
        if token = "}"
            return object
        if token != ","
            throw Error("Expected JSON object delimiter at " (position - 1))
        JsonSkipWhitespace(text, &position)
    }
}

JsonParseArray(text, &position) {
    array := []
    position += 1
    JsonSkipWhitespace(text, &position)
    if SubStr(text, position, 1) = "]" {
        position += 1
        return array
    }
    loop {
        array.Push(JsonParseValue(text, &position))
        JsonSkipWhitespace(text, &position)
        token := SubStr(text, position, 1)
        position += 1
        if token = "]"
            return array
        if token != ","
            throw Error("Expected JSON array delimiter at " (position - 1))
    }
}

JsonParseString(text, &position) {
    if SubStr(text, position, 1) != '"'
        throw Error("Expected JSON string at " position)
    position += 1
    result := ""
    while position <= StrLen(text) {
        character := SubStr(text, position, 1)
        position += 1
        if character = '"'
            return result
        if character != "\" {
            result .= character
            continue
        }
        escaped := SubStr(text, position, 1)
        position += 1
        if escaped = '"' || escaped = "\" || escaped = "/"
            result .= escaped
        else if escaped = "b"
            result .= Chr(8)
        else if escaped = "f"
            result .= Chr(12)
        else if escaped = "n"
            result .= "`n"
        else if escaped = "r"
            result .= "`r"
        else if escaped = "t"
            result .= "`t"
        else if escaped = "u" {
            result .= Chr(Integer("0x" SubStr(text, position, 4)))
            position += 4
        } else
            throw Error("Invalid JSON escape at " position)
    }
    throw Error("Unterminated JSON string")
}

JsonSkipWhitespace(text, &position) {
    while position <= StrLen(text) && InStr(" `t`r`n", SubStr(text, position, 1))
        position += 1
}

; This is the only left-button hook. Its context is deliberately narrow:
; modifier-drag anywhere in a managed window, or an unmodified HTCAPTION click
; that must focus without allowing Windows' native move loop to begin.
#HotIf ShouldHandleManagedLeftButton()
*LButton::HandleManagedLeftButton()
#HotIf

; Swallow Windows' native Alt+Tab and cycle only inside the active workspace.
; The wildcard forces AutoHotkey's keyboard hook and also handles Shift.
#HotIf GetKeyState("Alt", "P")
*Tab::{
    direction := GetKeyState("Shift", "P") ? "previous" : "next"
    Komorebic("cycle-focus " direction)
}
#HotIf

#HotIf ResizeMode
h::Komorebic("resize-axis horizontal decrease")
Left::Komorebic("resize-axis horizontal decrease")
l::Komorebic("resize-axis horizontal increase")
Right::Komorebic("resize-axis horizontal increase")
k::Komorebic("resize-axis vertical decrease")
Up::Komorebic("resize-axis vertical decrease")
j::Komorebic("resize-axis vertical increase")
Down::Komorebic("resize-axis vertical increase")
Enter::ExitResizeMode()
Escape::ExitResizeMode()
#HotIf

#HotIf IsMainModifierPressed() && !ResizeMode
h::{
    SendEvent("^!+{F9}")
    KeyWait("h")
}
Left::Komorebic("focus left")
j::Komorebic("focus down")
Down::Komorebic("focus down")
k::Komorebic("focus up")
Up::Komorebic("focus up")
l::Komorebic("focus right")
Right::Komorebic("focus right")
+h::Komorebic("resize-axis horizontal decrease")
+Left::Komorebic("resize-axis horizontal decrease")
+j::Komorebic("resize-axis vertical increase")
+Down::Komorebic("resize-axis vertical increase")
+k::Komorebic("resize-axis vertical decrease")
+Up::Komorebic("resize-axis vertical decrease")
+l::Komorebic("resize-axis horizontal increase")
+Right::Komorebic("resize-axis horizontal increase")
!h::Komorebic("move left")
!Left::Komorebic("move left")
!j::Komorebic("move down")
!Down::Komorebic("move down")
!k::Komorebic("move up")
!Up::Komorebic("move up")
!l::Komorebic("move right")
!Right::Komorebic("move right")
u::Komorebic("resize-axis horizontal decrease")
p::Komorebic("resize-axis horizontal increase")
i::Komorebic("resize-axis vertical decrease")
o::Komorebic("resize-axis vertical increase")
r::EnterResizeMode()
t::Komorebic("cycle-layout next")
v::Komorebic("toggle-float")
Space::Komorebic("cycle-focus next")
+p::Komorebic("toggle-pause")
+f::SendEvent("{F13 up}{F11}")
^f::ToggleMonocle()
^t::ToggleWindowsTaskbars()
^Backspace::{
    global ThemeEngine
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' ThemeEngine '" -Mode ApplySafe', , "Hide")
}
+m::Komorebic("minimize")
q::Komorebic("close")
m::{
    Komorebic("stop")
    ExitApp()
}
+w::Komorebic("retile")
$*Enter::{
    ; One mutually-exclusive dispatcher prevents the plain and Shift variants
    ; from competing when Caps or an optional external F13 mapping is held.
    openDropdown := GetKeyState("Shift", "P")
    if openDropdown
        ToggleDropdownTerminal()
    else
        LaunchWezTermWindow()

    ; Keep this hotkey thread alive until release so keyboard auto-repeat cannot
    ; create a second window from the same physical Enter press.
    KeyWait("Enter")
}
+e::ToggleDropdownApp("explorer")
+r::ToggleDropdownApp("notepad")
e::Run("explorer.exe")
b::Run('"' BraveExe '"')
$+s::Run("ms-screenclip:")
PrintScreen::Run('powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' ScreenshotHelper '"', , "Hide")
a::CycleWorkspace("previous")
s::CycleWorkspace("next")
d::ToggleYasbQuickLaunch()
w::SendEvent("^!+{F12}")
1::FocusWorkspace(0)
2::FocusWorkspace(1)
3::FocusWorkspace(2)
4::FocusWorkspace(3)
5::FocusWorkspace(4)
+1::MoveAndFollow(0)
+2::MoveAndFollow(1)
+3::MoveAndFollow(2)
+4::MoveAndFollow(3)
+5::MoveAndFollow(4)
+a::Komorebic("cycle-move-to-monitor previous")
+d::Komorebic("cycle-move-to-monitor previous")
^Right::Komorebic("cycle-move-to-monitor next")
^Down::Komorebic("cycle-move-to-monitor next")
#HotIf

; Reserve Super for this configuration and prevent Windows Start from opening
; when either Windows key is pressed by itself. Physical-state shortcut
; detection above continues to work for all configured Super chords.
*LWin::return
*RWin::return

#HotIf MainModifier = "Caps"
*CapsLock::return
*F13::return
#HotIf
