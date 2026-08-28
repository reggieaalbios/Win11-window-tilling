[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = (Get-Item -LiteralPath (Join-Path $repositoryRoot 'src\Win11WindowTiling.psm1')).FullName
$module = Import-Module -Name $modulePath -Force -PassThru
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wwt-lifecycle-' + [guid]::NewGuid().ToString('N'))

try {
    $source = Join-Path $testRoot 'source.txt'
    $destination = Join-Path $testRoot 'profile\managed.txt'
    $backupRoot = Join-Path $testRoot 'backups\install'
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    [IO.File]::WriteAllText($destination, 'before-install')
    [IO.File]::WriteAllText($source, 'managed-v1')

    $firstRecords = New-Object 'System.Collections.Generic.List[object]'
    & $module {
        param($Source,$Destination,$BackupRoot,$Records)
        Copy-WwtManagedFile -Source $Source -Destination $Destination -BackupRoot $BackupRoot -Records $Records
    } $source $destination $backupRoot $firstRecords
    $first = $firstRecords[0]
    if (-not $first.existed -or -not (Test-Path -LiteralPath $first.backup)) {
        throw 'Initial install did not capture the pre-install file.'
    }
    if ((Get-Content -LiteralPath $first.backup -Raw) -ne 'before-install') {
        throw 'Initial backup content is incorrect.'
    }

    # Simulate a user edit followed by Repair. Repair may restore the managed
    # file, but it must preserve both the original uninstall baseline and a
    # recovery copy of the overwritten edit.
    [IO.File]::WriteAllText($destination, 'user-edit-after-install')
    [IO.File]::WriteAllText($source, 'managed-v2')
    $repairRecords = New-Object 'System.Collections.Generic.List[object]'
    $repairRoot = Join-Path $testRoot 'backups\repair'
    & $module {
        param($Source,$Destination,$BackupRoot,$Records,$ExistingRecord)
        Copy-WwtManagedFile -Source $Source -Destination $Destination -BackupRoot $BackupRoot -Records $Records -ExistingRecord $ExistingRecord
    } $source $destination $repairRoot $repairRecords ([pscustomobject]$first)
    $repair = $repairRecords[0]

    if ($repair.backup -ne $first.backup -or -not $repair.existed) {
        throw 'Repair replaced the original uninstall baseline.'
    }
    if (@($repair.overwrittenBackups).Count -ne 1 -or
        (Get-Content -LiteralPath $repair.overwrittenBackups[0] -Raw) -ne 'user-edit-after-install') {
        throw 'Repair did not preserve the overwritten user edit.'
    }
    if ((Get-Content -LiteralPath $destination -Raw) -ne 'managed-v2') {
        throw 'Repair did not deploy the new managed content.'
    }

    [pscustomobject]@{
        Status = 'PASS'
        OriginalBaselinePreserved = $true
        RepairEditRecoveryPreserved = $true
    }
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
