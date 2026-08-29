
function winget {
    & winget.exe @args

    $env:Path =
        [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# Windows Terminal tabs inherit the environment of the existing Terminal
# process. Refresh PATH from the persistent registry values for every shell.
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = [Environment]::ExpandEnvironmentVariables("$machinePath;$userPath")

# Enable zoxide's `z` command when zoxide is installed and available on PATH.
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    (& zoxide init powershell | Out-String) | Invoke-Expression
}

# Render the PowerShell prompt with the locally cached Catppuccin Mocha theme.
# Keeping the theme on disk avoids a network request during shell startup.
# Oh My Posh is already active when this profile is dot-sourced with `. $PROFILE`.
# Reinitializing it makes its generated cleanup code call PSReadLine positionally,
# which is incompatible with this Windows PowerShell 5.1/PSReadLine combination.
if ((Get-Command oh-my-posh -ErrorAction SilentlyContinue) -and
    -not (Get-Command Set-PoshContext -ErrorAction SilentlyContinue)) {
    (& oh-my-posh init powershell --config "{{USER_PROFILE_WIN}}\.config\ohmyposh\catppuccin_mocha.omp.json" | Out-String) | Invoke-Expression
}

function dls  { Set-Location "$HOME\Downloads" }
function docs { Set-Location "$HOME\Documents" }
function desk { Set-Location "$HOME\Desktop" }
function dev  { Set-Location "$HOME\Dev"}
function home { Set-Location "$HOME" }
function win  { Set-Location "$HOME\Dev\Win11-window-tilling"}

function gs   { git status @args }
function gb   { git branch @args }
function gr   { git remote @args }
function gsw  { git switch @args }
function gtl   { git log --graph --oneline --decorate }

function op   { micro $PROFILE }
function t    { tldr @args }
function la   { eza -lah @args }

function Restart-Komorebi {
    $komorebicPath = Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe'
    $autoHotkeyPath = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
    $hotkeyConfigPath = Join-Path $env:USERPROFILE '.config\komorebi\komorebi.ahk'

    foreach ($requiredPath in @($komorebicPath, $autoHotkeyPath, $hotkeyConfigPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Komorebi reload dependency is missing: $requiredPath"
        }
    }

    if (Get-Process komorebi -ErrorAction SilentlyContinue) {
        & $komorebicPath stop
        if ($LASTEXITCODE) { throw "Komorebi stop failed with exit code $LASTEXITCODE." }
    }

    Start-Process -FilePath $autoHotkeyPath `
        -ArgumentList ('"{0}"' -f $hotkeyConfigPath) `
        -WindowStyle Hidden
}

function Restart-KomorebiHotkeys {
    $autoHotkeyPath = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
    $hotkeyConfigPath = Join-Path $env:USERPROFILE '.config\komorebi\komorebi.ahk'
    foreach ($requiredPath in @($autoHotkeyPath, $hotkeyConfigPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "AutoHotkey reload dependency is missing: $requiredPath"
        }
    }
    Start-Process -FilePath $autoHotkeyPath `
        -ArgumentList ('"{0}"' -f $hotkeyConfigPath) `
        -WindowStyle Hidden
}

function Restart-Yasb {
    $yasbcPath = Join-Path $env:ProgramFiles 'YASB\yasbc.exe'
    if (-not (Test-Path -LiteralPath $yasbcPath)) {
        throw "YASB reload dependency is missing: $yasbcPath"
    }
    & $yasbcPath reload
    if ($LASTEXITCODE) { throw "YASB reload failed with exit code $LASTEXITCODE." }
}

function re {
    if ($args.Count -ne 1) {
        Write-Output 'Usage: re --kr | --ys | --ahk | --all'
        return
    }

    switch ($args[0]) {
        '--kr'  { Restart-Komorebi }
        '--ys'  { Restart-Yasb }
        '--ahk' { Restart-KomorebiHotkeys }
        '--all' { Restart-Komorebi; Restart-Yasb }
        default { throw "Unknown reload target '$($args[0])'. Usage: re --kr | --ys | --ahk | --all" }
    }
}

Set-Alias clip Set-Clipboard
Set-Alias kreload Restart-Komorebi
Set-Alias kr Restart-Komorebi
