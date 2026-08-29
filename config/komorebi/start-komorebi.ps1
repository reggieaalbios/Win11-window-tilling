$ErrorActionPreference = 'Stop'

$sessionId = (Get-Process -Id $PID).SessionId
$configHome = Join-Path $env:USERPROFILE '.config\komorebi'
$startupLog = Join-Path $configHome 'startup.log'
$autoHotkeyCandidates = @(
    (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
)
$autoHotkey = @($autoHotkeyCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
$komorebiScript = Join-Path $configHome 'komorebi.ahk'
$komorebi = Join-Path $env:ProgramFiles 'komorebi\bin\komorebi.exe'
$komorebic = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
$komorebiConfig = Join-Path $configHome 'komorebi.json'
$themeEngine = Join-Path $env:USERPROFILE '.config\theme-engine\theme-engine.ps1'
$managedYasb = Join-Path $env:LOCALAPPDATA 'Win11WindowTilling\runtime\YASB\yasb.exe'
$installedYasb = Join-Path $env:ProgramFiles 'YASB\yasb.exe'
$yasb = if (Test-Path -LiteralPath $installedYasb) { $installedYasb } else { $managedYasb }
$dwmBlurGlassTask = 'DWMBlurGlass_Extend'

function Test-SessionProcess {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq $sessionId |
        Select-Object -First 1)
}

function Test-KomorebiHotkeys {
    # Another AutoHotkey script may already be running at logon. Match the
    # command line as well so that it cannot suppress this desktop script.
    return [bool](Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.SessionId -eq $sessionId -and
            $_.CommandLine -like "*$komorebiScript*"
        } |
        Select-Object -First 1)
}

function Start-KomorebiHotkeys {
    if (Test-KomorebiHotkeys) { return }
    if (-not $autoHotkey -or -not (Test-Path -LiteralPath $autoHotkey)) {
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) missing AutoHotkey v2: $($autoHotkeyCandidates -join '; ')"
        return
    }
    if (-not (Test-Path -LiteralPath $komorebiScript)) {
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) missing: $komorebiScript"
        return
    }
    Start-Process -FilePath $autoHotkey -ArgumentList ('"{0}"' -f $komorebiScript) -WindowStyle Hidden
}

function Start-SessionProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgumentList = '',
        [switch]$Hidden
    )
    if (Test-SessionProcess $Name) { return }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) missing: $FilePath"
        return
    }
    $startArguments = @{ FilePath = $FilePath }
    if ($ArgumentList) { $startArguments.ArgumentList = $ArgumentList }
    if ($Hidden) { $startArguments.WindowStyle = 'Hidden' }
    Start-Process @startArguments
}

function Test-KomorebiReady {
    if (-not (Test-SessionProcess 'komorebi') -or -not (Test-Path -LiteralPath $komorebic)) { return $false }
    try {
        & $komorebic state 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Start-KomorebiReliable {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (-not (Test-KomorebiReady)) {
            Get-Process -Name komorebi -ErrorAction SilentlyContinue |
                Where-Object SessionId -eq $sessionId |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            Start-SessionProcess 'komorebi' $komorebi ('--config "{0}"' -f $komorebiConfig) -Hidden
        }

        $readyDeadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $readyDeadline) {
            if (Test-KomorebiReady) {
                Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) Komorebi ready on attempt $attempt"
                return
            }
            Start-Sleep -Milliseconds 500
        }
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) Komorebi not ready after attempt $attempt"
    }
    throw 'Komorebi did not become ready after 5 attempts.'
}

Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) fast startup began (session $sessionId)"

# Explorer normally appears almost immediately. Waiting for its process avoids
# a race where Komorebi/YASB initialize against a desktop that does not exist.
$shellDeadline = (Get-Date).AddSeconds(15)
while (-not (Test-SessionProcess 'explorer') -and (Get-Date) -lt $shellDeadline) {
    Start-Sleep -Milliseconds 100
}

# Do not start the hotkey controller until Komorebi's IPC server answers. This
# prevents its fallback launcher from racing a slow logon-time process.
try {
    Start-KomorebiReliable
} catch {
    Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) startup failed: $($_.Exception.Message)"
    exit 1
}
Start-KomorebiHotkeys
Start-SessionProcess 'yasb' $yasb

# Recover an interrupted theme transaction before the user starts changing
# wallpapers. Startup mode is a no-op when the previous commit was clean.
if (Test-Path -LiteralPath $themeEngine) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Startup' -f $themeEngine) `
        -WindowStyle Hidden
}

# DWMBlurGlass installs its own elevated logon task. By checking after the main
# desktop stack is up, its official task gets time to start the host first.
try {
    $dwmBlurGlassHost = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'DWMBlurGlassHost*' } |
        Select-Object -First 1
    $dwmBlurGlassStartupTask = Get-ScheduledTask -TaskName $dwmBlurGlassTask -ErrorAction Stop
    if (-not $dwmBlurGlassHost -and $dwmBlurGlassStartupTask.State -ne 'Running') {
        Start-ScheduledTask -TaskName $dwmBlurGlassTask -ErrorAction Stop
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) requested DWMBlurGlass startup"
    } else {
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) DWMBlurGlass host already available"
    }
} catch {
    Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) DWMBlurGlass startup check failed: $($_.Exception.Message)"
}

Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) fast startup finished"
