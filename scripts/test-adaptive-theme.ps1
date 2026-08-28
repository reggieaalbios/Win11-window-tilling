[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wwt-theme-test-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $testRoot 'profile'
$localRoot = Join-Path $testRoot 'local'
$stateRoot = Join-Path $localRoot 'Win11WindowTilling\themes'

function New-TestWallpaper {
    param([string]$Path,[ValidateSet('Dark','Light')][string]$Kind)
    Add-Type -AssemblyName PresentationCore
    $width=48;$height=32;$stride=$width*4;$pixels=New-Object byte[] ($stride*$height)
    for($y=0;$y-lt$height;$y++){for($x=0;$x-lt$width;$x++){
        $offset=$y*$stride+$x*4;$phase=($x+$y)%3
        if($Kind-eq'Dark'){$base=12+[int](55*$x/$width);$r=$base+($phase*18);$g=$base+25;$b=$base+60}
        else{$base=205+[int](45*$x/$width);$r=$base;$g=$base-($phase*12);$b=245-($phase*8)}
        $pixels[$offset]=[byte][Math]::Min(255,$b);$pixels[$offset+1]=[byte][Math]::Min(255,$g);$pixels[$offset+2]=[byte][Math]::Min(255,$r);$pixels[$offset+3]=255
    }}
    $bitmap=New-Object Windows.Media.Imaging.WriteableBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null)
    $bitmap.WritePixels((New-Object Windows.Int32Rect(0,0,$width,$height)),$pixels,$stride,0)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($Path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
}

try {
    New-Item -ItemType Directory -Path $profileRoot,$localRoot -Force | Out-Null
    & (Join-Path $PSScriptRoot 'render-config.ps1') -OutputRoot $profileRoot -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot | Out-Null
    $modulePath=Join-Path $profileRoot '.config\theme-engine\AdaptiveTheme.psm1'
    Import-Module $modulePath -Force
    $dword=& (Get-Module AdaptiveTheme) { Convert-ToRegistryDword -3379059 }
    if([uint64]$dword-ne4291588237){throw "Signed DWM DWORD conversion regressed: $dword"}
    $darkImage=Join-Path $testRoot 'dark.png';$lightImage=Join-Path $testRoot 'light.png'
    New-TestWallpaper $darkImage Dark;New-TestWallpaper $lightImage Light

    $dark=Invoke-AdaptiveTheme -Mode Generate -Image $darkImage -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    $darkAgain=Invoke-AdaptiveTheme -Mode Generate -Image $darkImage -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    $light=Invoke-AdaptiveTheme -Mode Generate -Image $lightImage -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    if($dark.mode-ne'dark'-or$light.mode-ne'light'){throw "Expected dark and light modes; got $($dark.mode) and $($light.mode)."}
    if(($dark.roles|ConvertTo-Json -Compress)-ne($darkAgain.roles|ConvertTo-Json -Compress)){throw 'Palette generation is not deterministic.'}
    foreach($theme in @($dark,$light)){if(@($theme.contrastResults|Where-Object{[double]$_.ratio-lt[double]$_.minimum}).Count){throw 'A generated theme failed contrast validation.'};if([double]$theme.opacity.bar-gt.92){throw 'Opacity exceeded the 92 percent cap.'}}

    $applied=Invoke-AdaptiveTheme -Mode Apply -Image $darkImage -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    foreach($path in @('.config\yasb\styles.theme.css','.config\yasb\styles.css','.config\komorebi\komorebi.json','wwt-theme.lua','.config\ohmyposh\catppuccin_mocha.omp.json')){if(-not(Test-Path -LiteralPath (Join-Path $profileRoot $path))){throw "Theme adapter output is missing: $path"}}
    $lastGoodBefore=(Get-Content -LiteralPath (Join-Path $stateRoot 'last-good.json') -Raw|ConvertFrom-Json).transactionId
    $safe=Invoke-AdaptiveTheme -Mode ApplySafe -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    $lastGoodAfter=(Get-Content -LiteralPath (Join-Path $stateRoot 'last-good.json') -Raw|ConvertFrom-Json).transactionId
    if(-not$safe.fallback-or$lastGoodBefore-ne$lastGoodAfter){throw 'Safe fallback replaced the last-known-good theme.'}
    $restored=Invoke-AdaptiveTheme -Mode RestoreLastGood -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    if($restored.transactionId-ne$lastGoodBefore){throw 'Last-known-good restoration returned the wrong transaction.'}

    $recoveryRoot=Join-Path (Join-Path $stateRoot 'transactions') 'simulated-interruption';$recoveryBackup=Join-Path $recoveryRoot 'backup';New-Item -ItemType Directory -Path $recoveryBackup -Force|Out-Null
    $recoveryTarget=Join-Path $profileRoot '.config\yasb\styles.theme.css';$expectedText=[IO.File]::ReadAllText($recoveryTarget);$backupPath=Join-Path $recoveryBackup 'yasb-theme.txt';[IO.File]::WriteAllText($backupPath,$expectedText);[IO.File]::WriteAllText($recoveryTarget,'interrupted write')
    @{schemaVersion=1;transactionId='simulated-interruption';state='applying';records=@(@{name='yasb-theme';path=$recoveryTarget;existed=$true;backup=$backupPath});dwm=$null}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $recoveryRoot 'journal.json') -Encoding UTF8
    Invoke-AdaptiveTheme -Mode Startup -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent|Out-Null
    if([IO.File]::ReadAllText($recoveryTarget)-ne$expectedText-or-not(Test-Path -LiteralPath (Join-Path $recoveryRoot 'recovered.json'))){throw 'Startup did not recover an interrupted transaction.'}

    $corrupt=Join-Path $testRoot 'corrupt.png';[IO.File]::WriteAllText($corrupt,'not an image')
    $fallback=Invoke-AdaptiveTheme -Mode Apply -Image $corrupt -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    if(-not$fallback.fallback-or$fallback.wallpaper-ne$corrupt){throw 'Corrupt wallpaper did not commit the safe fallback with the requested wallpaper recorded.'}
    for($i=0;$i-lt5;$i++){Invoke-AdaptiveTheme -Mode ApplySafe -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent|Out-Null}
    $committed=@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'transactions') -Directory|Where-Object{Test-Path -LiteralPath (Join-Path $_.FullName 'committed.json')})
    if($committed.Count-gt5){throw "Transaction retention exceeded five snapshots: $($committed.Count)"}

    $doctor=Invoke-AdaptiveTheme -Mode Doctor -TargetUserProfile $profileRoot -TargetLocalAppData $localRoot -StateRoot $stateRoot -NoReload -NoSystemAccent
    if(-not$doctor.Healthy){throw 'Theme doctor did not report a healthy rendered profile.'}
    [pscustomobject]@{Status='PASS';DarkOpacity=$dark.opacity.bar;LightOpacity=$light.opacity.bar;DarkChecks=$dark.contrastResults.Count;LightChecks=$light.contrastResults.Count;Adapters=$applied.files.Count;Transactions=$committed.Count;InterruptedRecovery=$true}
}
finally {
    Remove-Module AdaptiveTheme -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
