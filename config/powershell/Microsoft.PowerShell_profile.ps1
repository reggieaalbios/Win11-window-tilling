
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

Set-Alias clip Set-Clipboard
