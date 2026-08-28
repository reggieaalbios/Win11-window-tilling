[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall','Validate')][string]$Mode = 'Validate',
    [string]$ArchivePath,
    [string]$ExpectedSHA256 = '32834FED77575353CF3699E3A5C182B8D4FCD7F00926C730E94D1A1DD591BD51',
    [string]$StatePath = (Join-Path $env:ProgramData 'Win11WindowTilling\dwmblurglass-state.json'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$taskName = 'DWMBlurGlass_Extend'
$destination = Join-Path $env:ProgramFiles 'DWMBlurGlass'

function Write-State($value) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $StatePath) -Force | Out-Null
    [IO.File]::WriteAllText($StatePath, ($value | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

if ($Mode -eq 'Validate') {
    if (-not $ArchivePath -or -not (Test-Path -LiteralPath $ArchivePath)) { throw 'DWMBlurGlass archive is missing.' }
    if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $ExpectedSHA256) { throw 'DWMBlurGlass archive hash mismatch.' }
    [pscustomobject]@{ Valid=$true; Archive=$ArchivePath; Destination=$destination; Apply=[bool]$Apply }
    return
}
if (-not $Apply) { [pscustomobject]@{ Mode=$Mode; Applied=$false; Destination=$destination }; return }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'DWMBlurGlass deployment requires an elevated installer process.'
}

if ($Mode -eq 'Uninstall') {
    if (-not (Test-Path -LiteralPath $StatePath)) { return }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    if ($state.backupDirectory -and (Test-Path -LiteralPath $state.backupDirectory)) {
        Move-Item -LiteralPath $state.backupDirectory -Destination $destination
    }
    if ($state.previousTaskXml) { Register-ScheduledTask -TaskName $taskName -Xml $state.previousTaskXml -Force | Out-Null }
    Remove-Item -LiteralPath $StatePath -Force
    return
}

if (-not $ArchivePath -or -not (Test-Path -LiteralPath $ArchivePath)) { throw 'DWMBlurGlass archive is missing.' }
if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $ExpectedSHA256) { throw 'DWMBlurGlass archive hash mismatch.' }
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($build -lt 22000) { throw "Unsupported Windows build $build." }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $env:ProgramData "Win11WindowTilling\backups\dwmblurglass-$stamp"
$previousTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$previousTaskXml = if ($previousTask) { Export-ScheduledTask -TaskName $taskName } else { $null }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('wwt-dwm-' + [guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $temporary
    $release = Join-Path $temporary 'Release'
    foreach ($required in @('DWMBlurGlassHost.dll','DWMBlurGlassGUI.exe','DWMBlurGlassExt.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $required))) { throw "DWMBlurGlass payload lacks $required." }
    }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $destination) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Move-Item -LiteralPath $destination -Destination $backup
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -Path (Join-Path $release '*') -Destination $destination -Recurse -Force
    $oldSymbols = Join-Path $backup 'data\symbols'
    if (Test-Path -LiteralPath $oldSymbols) { Copy-Item -LiteralPath $oldSymbols -Destination (Join-Path $destination 'data\symbols') -Recurse -Force }

    $action = New-ScheduledTaskAction -Execute (Join-Path $destination 'DWMBlurGlassHost.dll') -Argument 'runhost'
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description 'DWMBlurGlass Extension Host' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3
    $task = Get-ScheduledTask -TaskName $taskName
    if ($task.State -notin @('Running','Ready')) { throw "DWMBlurGlass host task entered state '$($task.State)'." }
    $symbols = @(Get-ChildItem (Join-Path $destination 'data\symbols') -Filter '*.pdb' -File -Recurse -ErrorAction SilentlyContinue)
    Write-State ([ordered]@{ schemaVersion=1; installedAt=(Get-Date).ToString('o'); destination=$destination; backupDirectory=if(Test-Path $backup){$backup}else{$null}; previousTaskXml=$previousTaskXml; symbolsPresent=($symbols.Count -ge 2); symbolRecovery='Host auto-downloads Microsoft symbols; preserved valid prior cache when available.' })
} catch {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $destination }
    if ($previousTaskXml) { Register-ScheduledTask -TaskName $taskName -Xml $previousTaskXml -Force | Out-Null }
    throw
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
