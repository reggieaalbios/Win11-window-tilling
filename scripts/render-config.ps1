[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputRoot,

    [string]$TargetUserProfile = $env:USERPROFILE,
    [string]$TargetProgramFiles = $env:ProgramFiles,
    [string]$TargetLocalAppData = $env:LOCALAPPDATA,
    [string]$TargetWallpaperDirectory,

    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Caps'
)

$ErrorActionPreference = 'Stop'

if (-not $TargetWallpaperDirectory) {
    $TargetWallpaperDirectory = Join-Path $TargetUserProfile 'Pictures\Wallpapers'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configRoot = Join-Path $repositoryRoot 'config'
$resolvedOutput = [IO.Path]::GetFullPath($OutputRoot)

if ($resolvedOutput -eq [IO.Path]::GetPathRoot($resolvedOutput)) {
    throw 'OutputRoot cannot be a filesystem root.'
}

$destinationMap = [ordered]@{
    'komorebi' = '.config\komorebi'
    'yasb' = '.config\yasb'
    'ohmyposh' = '.config\ohmyposh'
    'theme-engine' = '.config\theme-engine'
}

New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

foreach ($entry in $destinationMap.GetEnumerator()) {
    $source = Join-Path $configRoot $entry.Key
    $destination = Join-Path $resolvedOutput $entry.Value
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Get-ChildItem -LiteralPath $destination -Directory -Recurse -Force |
        Where-Object Name -eq '__pycache__' |
        Remove-Item -Recurse -Force
    $sourceFiles = Get-ChildItem -LiteralPath $source -File -Recurse -Force |
        Where-Object {
            $_.Name -ne 'config.yaml.template' -and
            $_.FullName -notmatch '[\\/]__pycache__[\\/]'
        }
    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($source.Length).TrimStart('\')
        $targetFile = Join-Path $destination $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetFile) -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetFile -Force
    }
}

$wezTermSource = Join-Path $configRoot 'wezterm'
foreach ($wezTermFile in Get-ChildItem -LiteralPath $wezTermSource -File) {
    Copy-Item -LiteralPath $wezTermFile.FullName `
        -Destination (Join-Path $resolvedOutput $wezTermFile.Name) -Force
}

$wallpaperSource = Join-Path $repositoryRoot 'wallpapers'
$wallpaperDestination = Join-Path $resolvedOutput 'Pictures\Wallpapers'
New-Item -ItemType Directory -Path $wallpaperDestination -Force | Out-Null
# Keep the canonical wallpaper available for isolated rendering tests. The full
# pinned bank overwrites this byte-identical file during installation.
Copy-Item -LiteralPath (Join-Path $wallpaperSource 'jakoolit-anime-purple-eyes.png') `
    -Destination (Join-Path $wallpaperDestination 'Anime-Purple-eyes.png') -Force
Copy-Item -LiteralPath (Join-Path $wallpaperSource 'JAKOOLIT-WALLPAPER-SOURCE.txt') `
    -Destination $wallpaperDestination -Force

# Keep layout rules immutable at runtime. The adaptive engine composes this
# stable file with its generated color-only stylesheet into styles.css.
Copy-Item -LiteralPath (Join-Path $configRoot 'yasb\styles.css') `
    -Destination (Join-Path $resolvedOutput '.config\yasb\styles.layout.css') -Force

$profileDestination = Join-Path $resolvedOutput 'Documents\WindowsPowerShell'
New-Item -ItemType Directory -Path $profileDestination -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $configRoot 'powershell\Microsoft.PowerShell_profile.ps1') `
    -Destination $profileDestination -Force

$yasbTemplate = Join-Path $configRoot 'yasb\config.yaml.template'
$yasbDestination = Join-Path $resolvedOutput '.config\yasb\config.yaml'
$renderedYaml = [IO.File]::ReadAllText($yasbTemplate)

$tokens = [ordered]@{
    '{{USER_PROFILE_WIN}}' = $TargetUserProfile
    '{{USER_PROFILE_URI}}' = ($TargetUserProfile -replace '\\', '/')
    '{{PROGRAM_FILES_WIN}}' = $TargetProgramFiles
    '{{LOCAL_APP_DATA_WIN}}' = $TargetLocalAppData
    '{{WALLPAPER_DIR_YAML}}' = ($TargetWallpaperDirectory -replace '\\', '\\')
}

foreach ($token in $tokens.GetEnumerator()) {
    $renderedYaml = $renderedYaml.Replace($token.Key, $token.Value)
}

if ($renderedYaml -match '{{[A-Z0-9_]+}}') {
    throw "Unresolved configuration token: $($Matches[0])"
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($yasbDestination, $renderedYaml, $utf8NoBom)

$profileFile = Join-Path $profileDestination 'Microsoft.PowerShell_profile.ps1'
$renderedProfile = [IO.File]::ReadAllText($profileFile).
    Replace('{{USER_PROFILE_WIN}}', $TargetUserProfile).
    Replace('function op   { micro $PROFILE }', "function op   { micro `$PROFILE } ").
    Replace("`r`n", "`n")
[IO.File]::WriteAllText($profileFile, $renderedProfile, $utf8NoBom)

# Match the adaptive theme engine's canonical generated-file serialization.
$wezTermThemeFile = Join-Path $resolvedOutput 'wwt-theme.lua'
$renderedWezTermTheme = [IO.File]::ReadAllText($wezTermThemeFile).TrimEnd("`r", "`n")
[IO.File]::WriteAllText($wezTermThemeFile, $renderedWezTermTheme, $utf8NoBom)

$ohMyPoshFile = Join-Path $resolvedOutput '.config\ohmyposh\catppuccin_mocha.omp.json'
$renderedOhMyPosh = [IO.File]::ReadAllText($ohMyPoshFile) |
    ConvertFrom-Json |
    ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($ohMyPoshFile, $renderedOhMyPosh, $utf8NoBom)

$ahkDestination = Join-Path $resolvedOutput '.config\komorebi\komorebi.ahk'
$renderedAhk = [IO.File]::ReadAllText($ahkDestination).
    Replace('{{MAIN_MODIFIER_AHK}}', $MainModifier).
    Replace("`r`n", "`n")
[IO.File]::WriteAllText($ahkDestination, $renderedAhk, $utf8NoBom)

$komorebiDestination = Join-Path $resolvedOutput '.config\komorebi\komorebi.json'
$renderedKomorebi = [IO.File]::ReadAllText($komorebiDestination)
foreach ($token in $tokens.GetEnumerator()) {
    $renderedKomorebi = $renderedKomorebi.Replace($token.Key, $token.Value)
}
[IO.File]::WriteAllText($komorebiDestination, $renderedKomorebi, $utf8NoBom)

$shortcutsDestination = Join-Path $resolvedOutput '.config\yasb\shortcuts.json'
$renderedShortcuts = [IO.File]::ReadAllText($shortcutsDestination).
    Replace('{{MAIN_MODIFIER_LABEL}}', $MainModifier)
[IO.File]::WriteAllText($shortcutsDestination, $renderedShortcuts, $utf8NoBom)

$unresolvedFiles = @($ahkDestination, $komorebiDestination, $shortcutsDestination, $yasbDestination, $profileFile, $wezTermThemeFile, $ohMyPoshFile)
foreach ($unresolvedFile in $unresolvedFiles) {
    $content = [IO.File]::ReadAllText($unresolvedFile)
    if ($content -match '{{[A-Z0-9_]+}}') {
        throw "Unresolved configuration token in $unresolvedFile`: $($Matches[0])"
    }
}

[pscustomobject]@{
    OutputRoot = $resolvedOutput
    UserProfile = $TargetUserProfile
    ProgramFiles = $TargetProgramFiles
    WallpaperDirectory = $TargetWallpaperDirectory
    MainModifier = $MainModifier
}
