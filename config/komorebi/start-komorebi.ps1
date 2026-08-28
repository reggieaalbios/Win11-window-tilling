$ErrorActionPreference = 'Continue'

$sessionId = (Get-Process -Id $PID).SessionId
$configHome = Join-Path $env:USERPROFILE '.config\komorebi'
$startupLog = Join-Path $configHome 'startup.log'
$autoHotkey = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'
$komorebiScript = Join-Path $configHome 'komorebi.ahk'
$komorebi = Join-Path $env:ProgramFiles 'komorebi\bin\komorebi.exe'
$komorebiConfig = Join-Path $configHome 'komorebi.json'
$themeEngine = Join-Path $env:USERPROFILE '.config\theme-engine\theme-engine.ps1'
$managedYasb = Join-Path $env:LOCALAPPDATA 'Win11WindowTilling\runtime\YASB\yasb.exe'
$yasb = if (Test-Path -LiteralPath $managedYasb) { $managedYasb } else { Join-Path $env:ProgramFiles 'YASB\yasb.exe' }
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
    if (-not (Test-Path -LiteralPath $autoHotkey)) {
        Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) missing: $autoHotkey"
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

Add-Content -LiteralPath $startupLog -Value "$(Get-Date -Format o) fast startup began (session $sessionId)"

# Explorer normally appears almost immediately. Waiting for its process avoids
# a race where Komorebi/YASB initialize against a desktop that does not exist.
$shellDeadline = (Get-Date).AddSeconds(15)
while (-not (Test-SessionProcess 'explorer') -and (Get-Date) -lt $shellDeadline) {
    Start-Sleep -Milliseconds 100
}

# Start the desktop stack without waiting for each GUI application to finish.
# Repeat only missing processes, covering brief shell/app initialization races.
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Start-SessionProcess 'komorebi' $komorebi ('--config "{0}"' -f $komorebiConfig) -Hidden

    # Start-Process returns quickly, but wait briefly until the process is
    # observable so the AHK fallback cannot race and request a second instance.
    $komorebiDeadline = (Get-Date).AddSeconds(1)
    while (-not (Test-SessionProcess 'komorebi') -and (Get-Date) -lt $komorebiDeadline) {
        Start-Sleep -Milliseconds 50
    }

    Start-KomorebiHotkeys
    Start-SessionProcess 'yasb' $yasb
    Start-Sleep -Seconds 1
    if ((Test-SessionProcess 'komorebi') -and
        (Test-KomorebiHotkeys) -and
        (Test-SessionProcess 'yasb')) {
        break
    }
}

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
