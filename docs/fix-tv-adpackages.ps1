# fix-tv-adpackages.ps1
# Re-disable Skyworth ad/statistics system packages on Q6011 after each boot.
# Usage:
#   powershell -ExecutionPolicy Bypass -File fix-tv-adpackages.ps1
#   powershell -ExecutionPolicy Bypass -File fix-tv-adpackages.ps1 -Quiet

param([switch]$Quiet)

$ErrorActionPreference = 'SilentlyContinue'
$adb    = 'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
$serial = '0332493700221160007899'
$wifi   = '192.168.3.156:5555'

$pkgs = @(
    'com.tianci.ad',
    'com.skyworthdigital.ott.advert.app',
    'com.skyworthdigital.ottstatsv2',
    'com.skyworthdigital.logcollector',
    'com.skyworthdigital.autotest',
    'com.android.noticewidget',
    'com.skyworthdigital.ott.guide',
    'com.skyworthdigital.skycommonpropertymanager'
)

function Log($m) { if (-not $Quiet) { Write-Host $m } }

& $adb start-server | Out-Null

$online = $false
for ($i = 0; $i -lt 12; $i++) {
    if ((& $adb devices) -match "$serial\s+device") { $online = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $online) {
    & $adb connect $wifi | Out-Null
    for ($i = 0; $i -lt 6; $i++) {
        if ((& $adb devices) -match "$serial\s+device|$wifi\s+device") { $online = $true; break }
        Start-Sleep -Seconds 5
    }
}
if (-not $online) {
    Log 'device not connected (USB/WiFi)'
    exit 1
}

$target = if ((& $adb devices) -match "$serial\s+device") { $serial } else { $wifi }
Log "device online: $target"

foreach ($p in $pkgs) {
    & $adb -s $target shell am force-stop $p | Out-Null
    & $adb -s $target shell service call package 95 s16 $p i32 3 i32 0 i32 0 s16 com.android.shell | Out-Null
    Log "disabled: $p"
}

Start-Sleep -Seconds 2
Log '--- disabled packages ---'
& $adb -s $target shell "pm list packages -d"
