Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:SchemaVersion = 1
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-JsonFile {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Path)
    $parent=Split-Path -Parent $Path;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),$script:Utf8NoBom)
}

function Write-AtomicText {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent=Split-Path -Parent $Path;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($temporary,$Text,$script:Utf8NoBom);Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-ThemePaths {
    param([string]$TargetUserProfile=$env:USERPROFILE,[string]$TargetLocalAppData=$env:LOCALAPPDATA,[string]$StateRoot)
    if(-not $StateRoot){$StateRoot=Join-Path $TargetLocalAppData 'Win11WindowTilling\themes'}
    [pscustomobject]@{
        UserProfile=$TargetUserProfile;StateRoot=$StateRoot;CacheRoot=Join-Path $StateRoot 'cache';TransactionRoot=Join-Path $StateRoot 'transactions'
        LastGoodPath=Join-Path $StateRoot 'last-good.json';ActivePath=Join-Path $StateRoot 'active.json';LatestRequestPath=Join-Path $StateRoot 'latest-request.json';LogPath=Join-Path $StateRoot 'theme-engine.jsonl'
        SafeThemePath=Join-Path $TargetUserProfile '.config\theme-engine\safe-theme.json';YasbConfig=Join-Path $TargetUserProfile '.config\yasb\config.yaml'
        YasbLayout=Join-Path $TargetUserProfile '.config\yasb\styles.layout.css';YasbTheme=Join-Path $TargetUserProfile '.config\yasb\styles.theme.css';YasbStyles=Join-Path $TargetUserProfile '.config\yasb\styles.css';YasbAssets=Join-Path $TargetUserProfile '.config\yasb\assets'
        Komorebi=Join-Path $TargetUserProfile '.config\komorebi\komorebi.json';WezTermConfig=Join-Path $TargetUserProfile '.wezterm.lua';WezTermTheme=Join-Path $TargetUserProfile 'wwt-theme.lua';OhMyPosh=Join-Path $TargetUserProfile '.config\ohmyposh\catppuccin_mocha.omp.json'
    }
}

function Write-ThemeLog {
    param($Paths,[string]$Level,[string]$Event,[string]$Message,[string]$TransactionId)
    New-Item -ItemType Directory -Path $Paths.StateRoot -Force|Out-Null
    $entry=[ordered]@{timestamp=(Get-Date).ToUniversalTime().ToString('o');level=$Level;event=$Event;message=$Message;transactionId=$TransactionId}
    Add-Content -LiteralPath $Paths.LogPath -Value ($entry|ConvertTo-Json -Compress) -Encoding UTF8
}

function Convert-HexToRgb { param([string]$Hex) $v=$Hex.Trim().TrimStart('#');if($v.Length-ne 6){throw "Invalid RGB color: $Hex"};[pscustomobject]@{R=[Convert]::ToInt32($v.Substring(0,2),16);G=[Convert]::ToInt32($v.Substring(2,2),16);B=[Convert]::ToInt32($v.Substring(4,2),16)} }
function Convert-RgbToHex { param([double]$R,[double]$G,[double]$B) '#{0:X2}{1:X2}{2:X2}' -f [Math]::Max(0,[Math]::Min(255,[Math]::Round($R))),[Math]::Max(0,[Math]::Min(255,[Math]::Round($G))),[Math]::Max(0,[Math]::Min(255,[Math]::Round($B))) }
function Convert-SrgbToLinear { param([double]$Value) $v=$Value/255.0;if($v-le 0.04045){return $v/12.92};[Math]::Pow(($v+0.055)/1.055,2.4) }
function Convert-LinearToSrgb { param([double]$Value) $v=[Math]::Max(0.0,[Math]::Min(1.0,$Value));if($v-le 0.0031308){return 255*12.92*$v};255*(1.055*[Math]::Pow($v,1/2.4)-0.055) }

function Convert-RgbToOklab {
    param([double]$R,[double]$G,[double]$B)
    $r1=Convert-SrgbToLinear $R;$g1=Convert-SrgbToLinear $G;$b1=Convert-SrgbToLinear $B
    $l=0.4122214708*$r1+0.5363325363*$g1+0.0514459929*$b1;$m=0.2119034982*$r1+0.6806995451*$g1+0.1073969566*$b1;$s=0.0883024619*$r1+0.2817188376*$g1+0.6299787005*$b1
    $l=[Math]::Pow([Math]::Max(0.0,$l),1/3.0);$m=[Math]::Pow([Math]::Max(0.0,$m),1/3.0);$s=[Math]::Pow([Math]::Max(0.0,$s),1/3.0)
    [pscustomobject]@{L=0.2104542553*$l+0.7936177850*$m-0.0040720468*$s;A=1.9779984951*$l-2.4285922050*$m+0.4505937099*$s;B=0.0259040371*$l+0.7827717662*$m-0.8086757660*$s}
}

function Convert-OklabToHex {
    param([double]$L,[double]$A,[double]$B)
    $l=$L+0.3963377774*$A+0.2158037573*$B;$m=$L-0.1055613458*$A-0.0638541728*$B;$s=$L-0.0894841775*$A-1.2914855480*$B
    $l=$l*$l*$l;$m=$m*$m*$m;$s=$s*$s*$s
    Convert-RgbToHex (Convert-LinearToSrgb (4.0767416621*$l-3.3077115913*$m+0.2309699292*$s)) (Convert-LinearToSrgb (-1.2684380046*$l+2.6097574011*$m-0.3413193965*$s)) (Convert-LinearToSrgb (-0.0041960863*$l-0.7034186147*$m+1.7076147010*$s))
}

function Get-RelativeLuminance { param([string]$Hex) $c=Convert-HexToRgb $Hex;0.2126*(Convert-SrgbToLinear $c.R)+0.7152*(Convert-SrgbToLinear $c.G)+0.0722*(Convert-SrgbToLinear $c.B) }
function Get-ContrastRatio { param([string]$First,[string]$Second) $a=Get-RelativeLuminance $First;$b=Get-RelativeLuminance $Second;if($a-lt$b){$t=$a;$a=$b;$b=$t};($a+0.05)/($b+0.05) }
function Mix-ThemeColor { param([string]$First,[string]$Second,[double]$SecondAmount) $a=Convert-HexToRgb $First;$b=Convert-HexToRgb $Second;$t=[Math]::Max(0.0,[Math]::Min(1.0,$SecondAmount));Convert-RgbToHex ($a.R*(1-$t)+$b.R*$t) ($a.G*(1-$t)+$b.G*$t) ($a.B*(1-$t)+$b.B*$t) }
function Get-CompositedColor { param([string]$Backdrop,[string]$Overlay,[double]$Opacity) Mix-ThemeColor $Backdrop $Overlay $Opacity }
function Get-ReadableColor { param([string]$Background,[double]$Minimum=4.5) $light='#FFFFFF';$dark='#000000';if((Get-ContrastRatio $light $Background)-ge(Get-ContrastRatio $dark $Background)){$light}else{$dark} }
function Repair-ThemeContrast { param([string]$Foreground,[string]$Background,[double]$Minimum=3) if((Get-ContrastRatio $Foreground $Background)-ge$Minimum){return $Foreground};$target=Get-ReadableColor $Background $Minimum;for($i=1;$i-le20;$i++){$candidate=Mix-ThemeColor $Foreground $target ($i/20);if((Get-ContrastRatio $candidate $Background)-ge$Minimum){return $candidate}};$target }
function Convert-HexToRgba { param([string]$Hex,[double]$Alpha) $c=Convert-HexToRgb $Hex;'rgba({0}, {1}, {2}, {3})' -f $c.R,$c.G,$c.B,([Math]::Min(0.92,[Math]::Max(0.0,$Alpha)).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)) }

function Get-WicImageSamples {
    param([string]$Image,[int]$MaximumSize=96)
    if(-not(Test-Path -LiteralPath $Image)){throw "Wallpaper not found: $Image"}
    Add-Type -AssemblyName PresentationCore;Add-Type -AssemblyName WindowsBase
    $stream=[IO.File]::Open($Image,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{$decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);$source=$decoder.Frames[0]}finally{$stream.Dispose()}
    $scale=[Math]::Min(1.0,$MaximumSize/[double][Math]::Max($source.PixelWidth,$source.PixelHeight));if($scale-lt1){$source=New-Object Windows.Media.Imaging.TransformedBitmap($source,(New-Object Windows.Media.ScaleTransform($scale,$scale)))}
    $bitmap=New-Object Windows.Media.Imaging.FormatConvertedBitmap($source,[Windows.Media.PixelFormats]::Bgra32,$null,0);$stride=$bitmap.PixelWidth*4;$pixels=New-Object byte[] ($stride*$bitmap.PixelHeight);$bitmap.CopyPixels($pixels,$stride,0)
    $samples=New-Object 'System.Collections.Generic.List[object]'
    for($i=0;$i-lt$pixels.Length;$i+=4){$alpha=$pixels[$i+3];if($alpha-lt32){continue};$f=$alpha/255;$r=$pixels[$i+2]*$f+127*(1-$f);$g=$pixels[$i+1]*$f+127*(1-$f);$b=$pixels[$i]*$f+127*(1-$f);$lab=Convert-RgbToOklab $r $g $b;$samples.Add([pscustomobject]@{R=$r;G=$g;B=$b;L=$lab.L;A=$lab.A;LabB=$lab.B;Y=0.2126*(Convert-SrgbToLinear $r)+0.7152*(Convert-SrgbToLinear $g)+0.0722*(Convert-SrgbToLinear $b)})}
    if($samples.Count-lt8){throw "Wallpaper does not contain enough visible pixels (sample count: $($samples.Count))."};$samples
}

function Get-ThemeClusters {
    param($Samples,[string]$Hash,[int]$Count=8)
    $bytes=for($i=0;$i-lt$Hash.Length;$i+=2){[Convert]::ToByte($Hash.Substring($i,2),16)};$centers=@()
    for($c=0;$c-lt$Count;$c++){$offset=($c*4)%($bytes.Count-3);$seed=[BitConverter]::ToUInt32([byte[]]$bytes,$offset);$s=$Samples[$seed%$Samples.Count];$centers+=[pscustomobject]@{L=$s.L;A=$s.A;B=$s.LabB;Count=0}}
    for($iteration=0;$iteration-lt10;$iteration++){$sumL=New-Object double[] $Count;$sumA=New-Object double[] $Count;$sumB=New-Object double[] $Count;$counts=New-Object int[] $Count
        foreach($s in $Samples){$best=0;$distance=[double]::MaxValue;for($c=0;$c-lt$Count;$c++){$dl=$s.L-$centers[$c].L;$da=$s.A-$centers[$c].A;$db=$s.LabB-$centers[$c].B;$d=$dl*$dl+$da*$da+$db*$db;if($d-lt$distance){$distance=$d;$best=$c}};$sumL[$best]+=$s.L;$sumA[$best]+=$s.A;$sumB[$best]+=$s.LabB;$counts[$best]++}
        for($c=0;$c-lt$Count;$c++){if($counts[$c]){$centers[$c]=[pscustomobject]@{L=$sumL[$c]/$counts[$c];A=$sumA[$c]/$counts[$c];B=$sumB[$c]/$counts[$c];Count=$counts[$c]}}}}
    @($centers|Where-Object Count -gt 0|Sort-Object Count -Descending)
}

function New-SemanticTheme {
    param($Clusters,$Samples,[string]$WallpaperHash,[string]$Wallpaper)
    $sortedSamples=@($Samples|Sort-Object Y);$ys=@($sortedSamples|ForEach-Object Y);$median=[double]$ys[[int][Math]::Floor($ys.Count/2)];$mode=if($median-ge0.55){'light'}else{'dark'};$total=[double]$Samples.Count
    $cluster=$Clusters|Sort-Object @{Expression={([Math]::Sqrt($_.A*$_.A+$_.B*$_.B)+0.04)*($_.Count/$total)};Descending=$true}|Select-Object -First 1
    $targetL=if($mode-eq'dark'){[Math]::Max(0.62,[Math]::Min(0.78,$cluster.L))}else{[Math]::Max(0.42,[Math]::Min(0.58,$cluster.L))};$accent=Convert-OklabToHex $targetL $cluster.A $cluster.B
    $base=if($mode-eq'dark'){'#070B12'}else{'#F2F5F8'};$opposite=if($mode-eq'dark'){'#FFFFFF'}else{'#000000'};$background=Mix-ThemeColor $base $accent 0.08;$surface=Mix-ThemeColor $background $opposite 0.07;$surfaceAlt=Mix-ThemeColor $background $opposite 0.13
    $border=Repair-ThemeContrast (Mix-ThemeColor $background $accent 0.58) $background 3;$accent=Repair-ThemeContrast $accent $background 3;$text=Get-ReadableColor $background 4.5;$muted=Repair-ThemeContrast (Mix-ThemeColor $text $background 0.32) $background 4.5
    $roles=[ordered]@{background=$background;surface=$surface;surfaceAlt=$surfaceAlt;text=$text;textMuted=$muted;border=$border;accent=$accent;accentSoft=Mix-ThemeColor $surface $accent 0.35;hover=Mix-ThemeColor $surface $accent 0.22;active=Mix-ThemeColor $surface $accent 0.55;focus=Repair-ThemeContrast (Mix-ThemeColor $accent $opposite 0.12) $background 3;selectedText=Get-ReadableColor $accent 4.5;success=Repair-ThemeContrast '#55D6A9' $background 3;warning=Repair-ThemeContrast '#F1C75B' $background 3;error=Repair-ThemeContrast '#FF6B7A' $background 3;cava1=Repair-ThemeContrast (Mix-ThemeColor $accent '#FFFFFF' 0.22) $background 3;cava2=$accent;cava3=Mix-ThemeColor $accent '#6C63FF' 0.35}
    $sampleColors=@();foreach($percentile in @(0.1,0.5,0.9)){$sample=$sortedSamples[[Math]::Min($sortedSamples.Count-1,[int][Math]::Floor(($sortedSamples.Count-1)*$percentile))];$sampleColors+=Convert-RgbToHex $sample.R $sample.G $sample.B}
    $barOpacity=0.50
    while($barOpacity-le0.92){$passes=$true;foreach($sampleColor in $sampleColors){$composited=Get-CompositedColor $sampleColor $background $barOpacity;if((Get-ContrastRatio $text $composited)-lt4.5){$passes=$false;break}};if($passes){break};$barOpacity=[Math]::Round($barOpacity+0.05,2)}
    if($barOpacity-gt0.92){throw 'No translucent surface up to the 92 percent opacity cap passes composited contrast validation.'}
    $checks=@([ordered]@{name='text/background';ratio=[Math]::Round((Get-ContrastRatio $roles.text $roles.background),2);minimum=4.5},[ordered]@{name='muted/background';ratio=[Math]::Round((Get-ContrastRatio $roles.textMuted $roles.background),2);minimum=4.5},[ordered]@{name='accent/background';ratio=[Math]::Round((Get-ContrastRatio $roles.accent $roles.background),2);minimum=3},[ordered]@{name='border/background';ratio=[Math]::Round((Get-ContrastRatio $roles.border $roles.background),2);minimum=3},[ordered]@{name='selectedText/accent';ratio=[Math]::Round((Get-ContrastRatio $roles.selectedText $roles.accent),2);minimum=4.5})
    for($i=0;$i-lt$sampleColors.Count;$i++){$composited=Get-CompositedColor $sampleColors[$i] $background $barOpacity;$checks+=[ordered]@{name=('text/composited-'+@(10,50,90)[$i]);ratio=[Math]::Round((Get-ContrastRatio $text $composited),2);minimum=4.5}}
    $failedChecks=@($checks|Where-Object{$_.ratio-lt$_.minimum});if($failedChecks.Count){throw ('Generated semantic palette failed contrast validation: '+(($failedChecks|ForEach-Object{"$($_.name)=$($_.ratio)<$($_.minimum)"})-join', '))}
    [ordered]@{schemaVersion=$script:SchemaVersion;wallpaper=$Wallpaper;wallpaperHash=$WallpaperHash;generatedAt=(Get-Date).ToUniversalTime().ToString('o');mode=$mode;opacity=[ordered]@{bar=$barOpacity;popup=[Math]::Min(0.78,[Math]::Max(0.68,$barOpacity+0.10))};source=[ordered]@{medianLuminance=[Math]::Round($median,4);sampleCount=$Samples.Count;clusterCount=@($Clusters).Count};roles=$roles;contrastResults=$checks}
}

function New-WallpaperTheme { param([string]$Image) $resolved=(Resolve-Path -LiteralPath $Image).Path;$hash=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$samples=Get-WicImageSamples $resolved;$clusters=Get-ThemeClusters $samples $hash;New-SemanticTheme $clusters $samples $hash $resolved }
function Get-SafeTheme { param($Paths) if(-not(Test-Path -LiteralPath $Paths.SafeThemePath)){throw "Safe theme is missing: $($Paths.SafeThemePath)"};Get-Content -LiteralPath $Paths.SafeThemePath -Raw|ConvertFrom-Json }

function New-YasbThemeCss {
    param($Theme)$r=$Theme.roles;$barOpacity=.55;$popupOpacity=.68;if($Theme.PSObject.Properties.Name-contains'opacity'){$barOpacity=[double]$Theme.opacity.bar;$popupOpacity=[double]$Theme.opacity.popup};$bg=Convert-HexToRgba $r.background $barOpacity;$popup=Convert-HexToRgba $r.background $popupOpacity;$surface=Convert-HexToRgba $r.surface ([Math]::Min(.78,$barOpacity+.04));$soft=Convert-HexToRgba $r.accentSoft .42;$hover=Convert-HexToRgba $r.hover .70;$active=Convert-HexToRgba $r.active .86
@"
/* Generated by Win11 Window Tiling adaptive theme. Do not edit. */
* { color: $($r.text); }
.yasb-bar { background-color: $bg; }
.windows-icon-widget, .komorebi-workspaces .ws-btn, .cpu-widget:hover, .memory-widget:hover, .traffic-widget:hover, .volume-widget:hover { background-color: $soft; }
.komorebi-workspaces .ws-btn { color: $($r.textMuted); }
.komorebi-workspaces .ws-btn:hover, .komorebi-workspaces .ws-btn.populated { color: $($r.text); background-color: $hover; }
.komorebi-workspaces .ws-btn.active { color: $($r.selectedText); background-color: $active; border-color: $($r.focus); }
.komorebi-workspaces .ws-btn.active .label { border-color: $($r.focus); }
.datetime-grouper .container { background-color: $surface; border-color: $($r.border); }
.workspace-separator { background-color: $($r.border); }
.wallpapers-gallery-window, .dark.wallpapers-gallery-window { background-color: $popup; border-color: $($r.border); color: $($r.text); }
.wallpapers-gallery-image { border-color: $($r.border); }
.wallpapers-gallery-image:hover { border-color: $($r.accent); }
.wallpapers-gallery-image.focused { border-color: $($r.focus); }
.wallpapers-gallery-buttons { color: $($r.text); background-color: $soft; border-color: $($r.border); }
.wallpapers-gallery-buttons:hover { color: $($r.selectedText); background-color: $active; border-color: $($r.focus); }
.power-menu-popup, .quick-launch-popup .container, .shortcut-guide-popup, .whkd-popup { background-color: $popup; border-color: $($r.border); color: $($r.text); }
.power-menu-popup .button, .shortcut-guide-popup .shortcut-row, .whkd-popup .keybind-row { background-color: $surface; border-color: transparent; }
.power-menu-popup .button.hover, .shortcut-guide-popup .shortcut-row:hover, .whkd-popup .keybind-row:hover { background-color: $hover; border-color: $($r.border); }
.power-menu-popup .button .label, .quick-launch-popup .search .search-input, .quick-launch-popup .results-list-view, .shortcut-guide-popup .shortcut-description, .whkd-popup .keybind-command { color: $($r.text); }
.power-menu-popup .button .icon, .quick-launch-popup .search .loader-line, .shortcut-guide-popup .shortcut-plus, .whkd-popup .plus-separator { color: $($r.accent); }
.power-menu-popup .button.shutdown .icon { color: $($r.error); }
.power-menu-popup .button.restart .icon { color: $($r.cava2); }
.power-menu-popup .button.lock .icon { color: $($r.warning); }
.quick-launch-popup .search, .shortcut-guide-popup .shortcut-search, .whkd-popup .filter-input { color: $($r.text); background-color: $surface; border-color: $($r.border); }
.quick-launch-popup .search .prefix, .quick-launch-popup .results-list-view::item:selected { color: $($r.selectedText); background-color: $active; border-color: $($r.focus); }
.quick-launch-popup .results-list-view::item:hover { background-color: $hover; border-color: $($r.border); }
.quick-launch-popup .results-list-view .description, .quick-launch-popup .results-empty-text { color: $($r.textMuted); }
.shortcut-guide-popup .shortcut-section, .whkd-popup .keybind-header { color: $($r.accent); background-color: $soft; }
.shortcut-guide-popup .shortcut-key, .whkd-popup .keybind-button { color: $($r.text); background-color: $surface; border-color: $($r.focus); }
.shortcut-guide-popup .shortcut-key.special, .whkd-popup .keybind-button.special { color: $($r.selectedText); background-color: $active; }
.menu, .calendar, .audio-menu, .volume-menu, .traffic-menu, .cpu-menu, .memory-menu, .systray-popup { background-color: $popup; border-color: $($r.border); color: $($r.text); }
"@
}

function New-YasbConfigText { param([string]$Text,$Theme)$r=$Theme.roles;$Text=[regex]::Replace($Text,'(?m)^(\s*border_color:\s*)"#[0-9A-Fa-f]{6}"',('$1"'+$r.border+'"'));$Text=[regex]::Replace($Text,'(?m)^(\s*foreground:\s*)"#[0-9A-Fa-f]{6}"',('$1"'+$r.cava1+'"'));$Text=[regex]::Replace($Text,'(?m)^(\s*gradient_color_1:\s*)"#[0-9A-Fa-f]{6}"',('$1"'+$r.cava1+'"'));$Text=[regex]::Replace($Text,'(?m)^(\s*gradient_color_2:\s*)"#[0-9A-Fa-f]{6}"',('$1"'+$r.cava2+'"'));[regex]::Replace($Text,'(?m)^(\s*gradient_color_3:\s*)"#[0-9A-Fa-f]{6}"',('$1"'+$r.cava3+'"')) }
function New-YasbIconText { param([string]$Text,$Theme) [regex]::Replace($Text,'(?i)(stroke|fill|stop-color)="#[0-9a-f]{6}"',('$1="'+$Theme.roles.accent+'"')) }
function New-KomorebiText { param([string]$Text,$Theme)$j=$Text|ConvertFrom-Json;$r=$Theme.roles;foreach($n in @('single','stack','monocle','floating')){$j.border_colours.$n=$r.focus};$j.border_colours.unfocused=$r.border;$j.border_colours.unfocused_locked=$r.accentSoft;$j|ConvertTo-Json -Depth 30 }
function New-WezTermThemeText { param($Theme)$r=$Theme.roles;@"
-- Generated by Win11 Window Tiling adaptive theme. Do not edit.
return { colors = { background = "$($r.background)", foreground = "$($r.text)", cursor_bg = "$($r.accent)", cursor_fg = "$($r.selectedText)", cursor_border = "$($r.accent)", selection_bg = "$($r.active)", selection_fg = "$($r.selectedText)", ansi = { "$($r.background)", "$($r.error)", "$($r.success)", "$($r.warning)", "$($r.cava3)", "$($r.accentSoft)", "$($r.cava1)", "$($r.text)" }, brights = { "$($r.surfaceAlt)", "$($r.error)", "$($r.success)", "$($r.warning)", "$($r.cava3)", "$($r.accentSoft)", "$($r.cava1)", "#FFFFFF" } }, window_background_opacity = 0.50 }
"@ }
function New-OhMyPoshText { param([string]$Text,$Theme)$j=$Text|ConvertFrom-Json;$r=$Theme.roles;$j.palette.blue=$r.cava2;$j.palette.lavender=$r.cava3;$j.palette.os=$r.textMuted;$j.palette.pink=$r.accent;$j.palette.closer=$r.text;$j|ConvertTo-Json -Depth 30 }

function Get-ThemeTargets {
    param($Paths,$Theme,[string]$TransactionRoot)
    if(-not(Test-Path -LiteralPath $Paths.YasbLayout)){if(-not(Test-Path -LiteralPath $Paths.YasbStyles)){throw "YASB stylesheet not found: $($Paths.YasbStyles)"};Write-AtomicText $Paths.YasbLayout ([IO.File]::ReadAllText($Paths.YasbStyles))}
    $layout=[IO.File]::ReadAllText($Paths.YasbLayout);$css=New-YasbThemeCss $Theme;$targets=New-Object 'System.Collections.Generic.List[object]'
    $targets.Add([pscustomobject]@{Name='yasb-theme';Path=$Paths.YasbTheme;Text=$css});$targets.Add([pscustomobject]@{Name='yasb-styles';Path=$Paths.YasbStyles;Text=$layout.TrimEnd()+"`r`n`r`n"+$css})
    if(Test-Path -LiteralPath $Paths.YasbConfig){$targets.Add([pscustomobject]@{Name='yasb-config';Path=$Paths.YasbConfig;Text=New-YasbConfigText ([IO.File]::ReadAllText($Paths.YasbConfig)) $Theme})}
    foreach($icon in @('windows-logo.svg','cpu-neon.svg','ram-neon.svg','download-neon.svg','upload-neon.svg','volume-minimal.svg')){$path=Join-Path $Paths.YasbAssets $icon;if(Test-Path -LiteralPath $path){$targets.Add([pscustomobject]@{Name=('yasb-icon-'+[IO.Path]::GetFileNameWithoutExtension($icon));Path=$path;Text=New-YasbIconText ([IO.File]::ReadAllText($path)) $Theme})}}
    if(Test-Path -LiteralPath $Paths.Komorebi){$targets.Add([pscustomobject]@{Name='komorebi';Path=$Paths.Komorebi;Text=New-KomorebiText ([IO.File]::ReadAllText($Paths.Komorebi)) $Theme})}
    $targets.Add([pscustomobject]@{Name='wezterm-theme';Path=$Paths.WezTermTheme;Text=New-WezTermThemeText $Theme})
    if(Test-Path -LiteralPath $Paths.WezTermConfig){$targets.Add([pscustomobject]@{Name='wezterm-config';Path=$Paths.WezTermConfig;Text=[IO.File]::ReadAllText($Paths.WezTermConfig)})}
    if(Test-Path -LiteralPath $Paths.OhMyPosh){$targets.Add([pscustomobject]@{Name='ohmyposh';Path=$Paths.OhMyPosh;Text=New-OhMyPoshText ([IO.File]::ReadAllText($Paths.OhMyPosh)) $Theme})}
    $stage=Join-Path $TransactionRoot 'staged';New-Item -ItemType Directory -Path $stage -Force|Out-Null;foreach($target in $targets){$target|Add-Member NoteProperty StagePath (Join-Path $stage ($target.Name+'.txt'));[IO.File]::WriteAllText($target.StagePath,$target.Text,$script:Utf8NoBom)};$targets
}

function Get-DwmSnapshot { $path='HKCU:\Software\Microsoft\Windows\DWM';$values=[ordered]@{};foreach($n in @('AccentColor','ColorizationColor','ColorPrevalence')){try{$values[$n]=Get-ItemPropertyValue -LiteralPath $path -Name $n -ErrorAction Stop}catch{$values[$n]=$null}};[pscustomobject]$values }
function Convert-ToRegistryDword { param($Value)if($Value-is[uint32]){return $Value};if([int64]$Value-lt0){return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Value),0)};[uint32]$Value }
function Send-DwmRefresh {
    if(-not('Wwt.NativeMethods'-as[type])){Add-Type -TypeDefinition 'namespace Wwt { public static class NativeMethods { [System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto, SetLastError=true)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint flags, uint timeout, out System.IntPtr result); } }'}
    $result=[IntPtr]::Zero;[void][Wwt.NativeMethods]::SendMessageTimeout([IntPtr]0xffff,0x001A,[IntPtr]::Zero,'ImmersiveColorSet',2,1000,[ref]$result)
}
function Restore-DwmSnapshot { param($Snapshot)$path='HKCU:\Software\Microsoft\Windows\DWM';foreach($p in $Snapshot.PSObject.Properties){if($null-eq$p.Value){Remove-ItemProperty -LiteralPath $path -Name $p.Name -ErrorAction SilentlyContinue}else{Set-ItemProperty -LiteralPath $path -Name $p.Name -Type DWord -Value (Convert-ToRegistryDword $p.Value)}};Send-DwmRefresh }
function Set-DwmTheme { param($Theme)$c=Convert-HexToRgb $Theme.roles.accent;$alpha=[uint64]4278190080;$abgr=[uint32]($alpha-bor([uint64]$c.B-shl16)-bor([uint64]$c.G-shl8)-bor[uint64]$c.R);$argb=[uint32]($alpha-bor([uint64]$c.R-shl16)-bor([uint64]$c.G-shl8)-bor[uint64]$c.B);$path='HKCU:\Software\Microsoft\Windows\DWM';Set-ItemProperty -LiteralPath $path -Name AccentColor -Type DWord -Value $abgr;Set-ItemProperty -LiteralPath $path -Name ColorizationColor -Type DWord -Value $argb;Set-ItemProperty -LiteralPath $path -Name ColorPrevalence -Type DWord -Value 1;Send-DwmRefresh }

function Invoke-ThemeReload { param($Paths,[switch]$NoReload)if($NoReload){return};$k=Get-Command komorebic.exe -ErrorAction SilentlyContinue;if(-not$k){$p=Join-Path $env:ProgramFiles 'komorebi\bin\komorebic.exe';if(Test-Path -LiteralPath $p){$k=Get-Item $p}};if($k-and(Get-Process komorebi -ErrorAction SilentlyContinue)){& $k.Source reload-configuration|Out-Null;if($LASTEXITCODE){throw "Komorebi reload failed: $LASTEXITCODE"}};$y=Get-Command yasbc.exe -ErrorAction SilentlyContinue;if(-not$y){$p=Join-Path $env:ProgramFiles 'YASB\yasbc.exe';if(Test-Path -LiteralPath $p){$y=Get-Item $p}};if($y-and(Get-Process yasb -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 250;& $y.Source reload|Out-Null;if($LASTEXITCODE){throw "YASB reload failed: $LASTEXITCODE"}} }
function Backup-Targets { param($Targets,[string]$Root)$backup=Join-Path $Root 'backup';New-Item -ItemType Directory -Path $backup -Force|Out-Null;$records=@();foreach($t in $Targets){$r=[ordered]@{name=$t.Name;path=$t.Path;existed=Test-Path -LiteralPath $t.Path;backup=$null};if($r.existed){$r.backup=Join-Path $backup ($t.Name+'.txt');Copy-Item -LiteralPath $t.Path -Destination $r.backup -Force};$records+=[pscustomobject]$r};$records }
function Restore-Records { param($Records)foreach($r in $Records){if($r.existed-and$r.backup-and(Test-Path -LiteralPath $r.backup)){Copy-Item -LiteralPath $r.backup -Destination $r.path -Force}elseif(Test-Path -LiteralPath $r.path){Remove-Item -LiteralPath $r.path -Force}} }
function Save-AppliedTargets { param($Targets,[string]$Root)$applied=Join-Path $Root 'applied';New-Item -ItemType Directory -Path $applied -Force|Out-Null;$records=@();foreach($t in $Targets){$stored=Join-Path $applied ($t.Name+'.txt');Copy-Item -LiteralPath $t.Path -Destination $stored -Force;$records+=[ordered]@{name=$t.Name;path=$t.Path;stored=$stored}};$records }

function Restore-LastGoodTheme { param($Paths,[switch]$NoReload,[switch]$NoSystemAccent)if(-not(Test-Path -LiteralPath $Paths.LastGoodPath)){throw 'No last-known-good theme exists.'};$last=Get-Content -LiteralPath $Paths.LastGoodPath -Raw|ConvertFrom-Json;foreach($file in $last.files){Write-AtomicText $file.path ([IO.File]::ReadAllText($file.stored))};if(-not$NoSystemAccent-and$last.dwm){Restore-DwmSnapshot $last.dwm};Invoke-ThemeReload $Paths -NoReload:$NoReload;Write-JsonFile $last $Paths.ActivePath;$last }
function Remove-OldTransactions { param($Paths)if(-not(Test-Path -LiteralPath $Paths.TransactionRoot)){return};$dirs=@(Get-ChildItem -LiteralPath $Paths.TransactionRoot -Directory|Where-Object{Test-Path -LiteralPath (Join-Path $_.FullName 'committed.json')}|Sort-Object LastWriteTime -Descending);foreach($d in @($dirs|Select-Object -Skip 5)){Remove-Item -LiteralPath $d.FullName -Recurse -Force} }
function Repair-UnfinishedTransactions { param($Paths)if(-not(Test-Path -LiteralPath $Paths.TransactionRoot)){return};foreach($d in Get-ChildItem -LiteralPath $Paths.TransactionRoot -Directory){$journal=Join-Path $d.FullName 'journal.json';if((Test-Path -LiteralPath $journal)-and-not(Test-Path -LiteralPath (Join-Path $d.FullName 'committed.json'))){$state=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json;if($state.records){Restore-Records $state.records};if($state.dwm){Restore-DwmSnapshot $state.dwm};Rename-Item -LiteralPath $journal -NewName 'recovered.json' -Force;Write-ThemeLog $Paths warning transaction-recovered "Recovered $($d.Name)." $d.Name}} }

function Invoke-ThemeApply {
    param($Theme,$Paths,[switch]$NoReload,[switch]$NoSystemAccent,[string]$RequestId)
    $id=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8);$root=Join-Path $Paths.TransactionRoot $id;New-Item -ItemType Directory -Path $root -Force|Out-Null;$targets=Get-ThemeTargets $Paths $Theme $root;$records=Backup-Targets $targets $root;$dwm=if($NoSystemAccent){$null}else{Get-DwmSnapshot}
    Write-JsonFile ([ordered]@{schemaVersion=1;transactionId=$id;state='applying';requestId=$RequestId;startedAt=(Get-Date).ToUniversalTime().ToString('o');records=$records;dwm=$dwm}) (Join-Path $root 'journal.json')
    try{foreach($t in $targets){Write-AtomicText $t.Path ([IO.File]::ReadAllText($t.StagePath))};if(-not$NoSystemAccent){Set-DwmTheme $Theme};Invoke-ThemeReload $Paths -NoReload:$NoReload;$applied=Save-AppliedTargets $targets $root;$fallback=$false;if($Theme.PSObject.Properties.Name-contains'fallback'){$fallback=[bool]$Theme.fallback};$active=[ordered]@{schemaVersion=1;transactionId=$id;wallpaper=$Theme.wallpaper;wallpaperHash=$Theme.wallpaperHash;mode=$Theme.mode;fallback=$fallback;appliedAt=(Get-Date).ToUniversalTime().ToString('o');roles=$Theme.roles;contrastResults=$Theme.contrastResults;files=$applied;dwm=if($NoSystemAccent){$null}else{Get-DwmSnapshot}};Write-JsonFile $active $Paths.ActivePath;if(-not$fallback){Write-JsonFile $active $Paths.LastGoodPath};Write-JsonFile $active (Join-Path $root 'committed.json');Remove-Item -LiteralPath (Join-Path $root 'journal.json') -Force;Remove-OldTransactions $Paths;Write-ThemeLog $Paths info theme-committed "Committed $($Theme.mode) theme." $id;$active}
    catch{Restore-Records $records;if(-not$NoSystemAccent-and$dwm){Restore-DwmSnapshot $dwm};try{Invoke-ThemeReload $Paths -NoReload:$NoReload}catch{};Write-ThemeLog $Paths error theme-rollback $_.Exception.Message $id;throw}
}

function Invoke-AdaptiveTheme {
    [CmdletBinding()]param([ValidateSet('Apply','Generate','RestoreLastGood','ApplySafe','Doctor','Startup')][string]$Mode='Doctor',[string]$Image,[string]$TargetUserProfile=$env:USERPROFILE,[string]$TargetLocalAppData=$env:LOCALAPPDATA,[string]$StateRoot,[switch]$NoReload,[switch]$NoSystemAccent)
    $paths=Get-ThemePaths $TargetUserProfile $TargetLocalAppData $StateRoot;New-Item -ItemType Directory -Path $paths.StateRoot,$paths.CacheRoot,$paths.TransactionRoot -Force|Out-Null
    $request=$null
    if($Mode-in@('Apply','Generate','ApplySafe')){$request=[guid]::NewGuid().ToString('N');Write-JsonFile ([ordered]@{requestId=$request;image=$Image;requestedAt=(Get-Date).ToUniversalTime().ToString('o')}) $paths.LatestRequestPath}
    $mutex=New-Object Threading.Mutex($false,'Local\Win11WindowTilling.AdaptiveTheme');$locked=$false
    try{$locked=$mutex.WaitOne([TimeSpan]::FromSeconds(20));if(-not$locked){throw 'Timed out waiting for another theme transaction.'};Repair-UnfinishedTransactions $paths
        if($Mode-eq'Startup'){if(Test-Path -LiteralPath $paths.ActivePath){return Get-Content -LiteralPath $paths.ActivePath -Raw|ConvertFrom-Json};return $null}
        if($Mode-eq'Doctor'){return [pscustomobject]@{Healthy=(Test-Path -LiteralPath $paths.SafeThemePath)-and(Test-Path -LiteralPath $paths.YasbStyles);SafeTheme=$paths.SafeThemePath;Active=Test-Path -LiteralPath $paths.ActivePath;LastGood=Test-Path -LiteralPath $paths.LastGoodPath;StateRoot=$paths.StateRoot}}
        if($Mode-eq'RestoreLastGood'){return Restore-LastGoodTheme $paths -NoReload:$NoReload -NoSystemAccent:$NoSystemAccent}
        if($Mode-eq'ApplySafe'){$theme=Get-SafeTheme $paths;$theme|Add-Member NoteProperty fallback $true -Force;return Invoke-ThemeApply $theme $paths -NoReload:$NoReload -NoSystemAccent:$NoSystemAccent -RequestId $request}
        if(-not$Image){throw 'Image is required for Apply and Generate.'};$resolved=(Resolve-Path -LiteralPath $Image).Path;$hash=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$cache=Join-Path $paths.CacheRoot $hash;New-Item -ItemType Directory -Path $cache -Force|Out-Null;$palette=Join-Path $cache 'palette.json'
        try{if(Test-Path -LiteralPath $palette){$theme=Get-Content -LiteralPath $palette -Raw|ConvertFrom-Json}else{$theme=New-WallpaperTheme $resolved;Write-JsonFile $theme $palette}}catch{if($Mode-eq'Generate'){throw};Write-ThemeLog $paths warning palette-fallback $_.Exception.Message $null;$theme=Get-SafeTheme $paths;$theme.wallpaper=$resolved;$theme.wallpaperHash=$hash;$theme|Add-Member NoteProperty fallback $true -Force}
        if($Mode-eq'Generate'){return $theme};$latest=Get-Content -LiteralPath $paths.LatestRequestPath -Raw|ConvertFrom-Json;if($latest.requestId-ne$request){return [pscustomobject]@{Skipped=$true;Reason='Superseded by a newer wallpaper request.'}};Invoke-ThemeApply $theme $paths -NoReload:$NoReload -NoSystemAccent:$NoSystemAccent -RequestId $request
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

Export-ModuleMember -Function Invoke-AdaptiveTheme,New-WallpaperTheme,New-SemanticTheme,Get-ContrastRatio,New-YasbThemeCss,New-YasbConfigText,New-KomorebiText,New-WezTermThemeText,New-OhMyPoshText
