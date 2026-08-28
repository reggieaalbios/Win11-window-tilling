[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wwt-portable-test-' + [guid]::NewGuid().ToString('N'))
$renderScript = Join-Path $PSScriptRoot 'render-config.ps1'

& $renderScript `
    -OutputRoot $testRoot `
    -TargetUserProfile 'C:\Users\portable-test' `
    -TargetProgramFiles 'C:\Program Files' `
    -TargetLocalAppData 'C:\Users\portable-test\AppData\Local' `
    -TargetWallpaperDirectory 'C:\Users\portable-test\Pictures\Wallpapers' |
    Out-Null

$files = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force -File)
$forbiddenPatterns = @(
    [regex]::Escape($env:USERPROFILE),
    [regex]::Escape(($env:USERPROFILE -replace '\\', '/')),
    '{{[A-Z0-9_]+}}'
)

foreach ($pattern in $forbiddenPatterns) {
    $matches = @($files | Select-String -Pattern $pattern)
    if ($matches) {
        $locations = ($matches | ForEach-Object Path | Sort-Object -Unique) -join ', '
        throw "Portability check failed for '$pattern': $locations"
    }
}

foreach ($jsonFile in $files | Where-Object Extension -eq '.json') {
    Get-Content -LiteralPath $jsonFile.FullName -Raw | ConvertFrom-Json | Out-Null
}

$parseErrors = @()
foreach ($powerShellFile in $files | Where-Object Extension -eq '.ps1') {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    $parseErrors += $errors
}
if ($parseErrors) {
    throw ($parseErrors | Out-String)
}

$autoHotkeyCandidates = @(
    (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
)
$autoHotkey = @($autoHotkeyCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
$ahkScript = Join-Path $testRoot '.config\komorebi\komorebi.ahk'
if ($autoHotkey -and (Test-Path -LiteralPath $autoHotkey)) {
    & cmd.exe /d /c "`"$autoHotkey`" /ErrorStdOut `"$ahkScript`" --validate"
    if ($LASTEXITCODE -ne 0) {
        throw "AutoHotkey validation failed with exit code $LASTEXITCODE"
    }
}

$capsRoot = Join-Path ([IO.Path]::GetTempPath()) ('wwt-portable-caps-' + [guid]::NewGuid().ToString('N'))
& $renderScript -OutputRoot $capsRoot -TargetUserProfile 'C:\Users\portable-test' -MainModifier Caps | Out-Null
$capsAhk = Join-Path $capsRoot '.config\komorebi\komorebi.ahk'
$capsShortcuts = Join-Path $capsRoot '.config\yasb\shortcuts.json'
if ((Get-Content -LiteralPath $capsAhk -Raw) -notmatch 'MainModifier := "Caps"') {
    throw 'Caps modifier was not rendered into komorebi.ahk.'
}
if ((Get-Content -LiteralPath $capsShortcuts -Raw | ConvertFrom-Json).sections[0].items[0].keys[0] -ne 'Caps') {
    throw 'Caps modifier was not rendered into the YASB shortcut guide.'
}
if ($autoHotkey -and (Test-Path -LiteralPath $autoHotkey)) {
    & cmd.exe /d /c "`"$autoHotkey`" /ErrorStdOut `"$capsAhk`" --validate"
    if ($LASTEXITCODE -ne 0) {
        throw "Caps AutoHotkey validation failed with exit code $LASTEXITCODE"
    }
}

[pscustomobject]@{
    Status = 'PASS'
    RenderRoot = $testRoot
    FilesValidated = $files.Count
    JsonValidated = @($files | Where-Object Extension -eq '.json').Count
    PowerShellValidated = @($files | Where-Object Extension -eq '.ps1').Count
    AutoHotkeyValidated = [bool]($autoHotkey -and (Test-Path -LiteralPath $autoHotkey))
}
