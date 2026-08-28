[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputRoot,

    [string]$TargetUserProfile = $env:USERPROFILE,
    [string]$TargetProgramFiles = $env:ProgramFiles,
    [string]$TargetLocalAppData = $env:LOCALAPPDATA,
    [string]$TargetWallpaperDirectory,

    [ValidateSet('Win','Caps')]
    [string]$MainModifier = 'Win'
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
Get-ChildItem -LiteralPath $wallpaperSource -File -Filter '*.png' |
    Copy-Item -Destination $wallpaperDestination -Force

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

$ahkDestination = Join-Path $resolvedOutput '.config\komorebi\komorebi.ahk'
$renderedAhk = [IO.File]::ReadAllText($ahkDestination).Replace('{{MAIN_MODIFIER_AHK}}', $MainModifier)
[IO.File]::WriteAllText($ahkDestination, $renderedAhk, $utf8NoBom)

$shortcutsDestination = Join-Path $resolvedOutput '.config\yasb\shortcuts.json'
$renderedShortcuts = [IO.File]::ReadAllText($shortcutsDestination).
    Replace('{{MAIN_MODIFIER_LABEL}}', $MainModifier).
    Replace('"Caps"', ('"{0}"' -f $MainModifier))
[IO.File]::WriteAllText($shortcutsDestination, $renderedShortcuts, $utf8NoBom)

$unresolvedFiles = @($ahkDestination, $shortcutsDestination, $yasbDestination)
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
