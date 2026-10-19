# ============================================================
#  cam_recover.ps1 — 一键恢复画质（把相机从降级态救回 1080p）
#
#  背景: 系统空闲/低电量时 DRIPS 省电机制会删掉相机设备,
#        重新枚举后有时只剩 160x120 一档 -> 画面模糊。
#        重启相机设备可立即恢复。
#
#  用法: 双击 cam-recover.cmd（会自动提权）
#  特点: 只重启设备, 不改任何设置; 恢复后自动验证档位
# ============================================================

[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Continue'
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$log = Join-Path $dir 'recover-log.txt'
$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Say { param([string]$t, [string]$c = 'Gray') Write-Host $t -ForegroundColor $c }
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Find-Ffmpeg {
    $c = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $root = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $root) {
        $h = @(Get-ChildItem $root -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue -Depth 6 | Select-Object -First 1)
        if ($h.Count -gt 0) { return $h[0].FullName }
    }
    return $null
}
function Get-FormatInfo {
    $ff = Find-Ffmpeg
    if (-not $ff) { return $null }
    $o = & $ff -hide_banner -f dshow -list_options true -i video="Integrated Camera" 2>&1
    if ($o | Select-String -Pattern 'Unable to BindToObject|Could not find video device') { return $null }
    return [pscustomobject]@{
        Count   = @($o | Select-String -Pattern 'pixel_format').Count
        Has1080 = @($o | Select-String -Pattern '1920x1080').Count -gt 0
    }
}

Say ""
Say "=====================================================" Cyan
Say " 摄像头画质恢复  $now" Cyan
Say "=====================================================" Cyan

if (-not (Test-Admin)) {
    Say "[!] 需要管理员权限（重启设备）。请用 cam-recover.cmd 双击运行。" Red
    if (-not $NoPause) { Read-Host "按回车退出" }
    exit 1
}

$before = Get-FormatInfo
if ($before) {
    Say ("  恢复前: {0} 档格式, 含 1080p = {1}" -f $before.Count, $before.Has1080) $(if ($before.Has1080) { 'Green' } else { 'Yellow' })
} else {
    Say "  恢复前: 无法枚举（设备忙或不在位）" Yellow
}

# 找相机复合设备并重启
$compId = $null
$k = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue |
     Where-Object { $_.PSChildName -match 'VID_174F&PID_1820$' } | Select-Object -First 1
if ($k) {
    $i = Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($i) { $compId = "USB\$($k.PSChildName)\$($i.PSChildName)" }
}

Say ""
if ($compId) {
    Say "  重启相机复合设备: $compId"
    $r = pnputil /restart-device "$compId" 2>&1
    ($r | Select-Object -Last 2) | ForEach-Object { Say ("    " + $_) DarkGray }
} else {
    Say "  [!] 没找到相机复合设备，尝试重启根集线器" Yellow
    $r = pnputil /restart-device "USB\ROOT_HUB30\5&8b8e61a&0&0" 2>&1
    ($r | Select-Object -Last 2) | ForEach-Object { Say ("    " + $_) DarkGray }
}

Start-Sleep -Seconds 4
pnputil /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 4

$after = Get-FormatInfo
Say ""
if ($after) {
    Say ("  恢复后: {0} 档格式, 含 1080p = {1}" -f $after.Count, $after.Has1080) $(if ($after.Has1080) { 'Green' } else { 'Yellow' })
    if ($after.Has1080 -and (-not $before -or -not $before.Has1080)) {
        Say "  [OK] 已恢复！画面应该清晰了。" Green
        $res = 'RESTORED'
    } elseif ($after.Has1080) {
        Say "  [OK] 本来就是正常的（无需恢复）。" Green
        $res = 'ALREADY-OK'
    } else {
        Say "  [!] 仍是降级态。建议完全关机再开机；若持续模糊请看 README-v2.md 的电源章节。" Yellow
        $res = 'STILL-DEGRADED'
    }
} else {
    Say "  [!] 恢复后无法枚举，请打开「相机」应用试一下。" Yellow
    $res = 'UNKNOWN'
}

Add-Content -LiteralPath $log -Value ("[{0}] {1} | before={2}/{3} after={4}/{5}" -f $now, $res,
    $(if ($before) { $before.Count } else { '?' }), $(if ($before) { $before.Has1080 } else { '?' }),
    $(if ($after) { $after.Count } else { '?' }), $(if ($after) { $after.Has1080 } else { '?' })) -Encoding UTF8

Say ""
Say "  日志: $log"
Say "=====================================================" Cyan
if (-not $NoPause) { Read-Host "按回车退出" }
