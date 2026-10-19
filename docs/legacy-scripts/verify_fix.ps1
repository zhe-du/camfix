# ============================================================
#  verify_fix.ps1 — 复查摄像头修复是否生效 (免管理员)
#
#  回答三个问题:
#    1) 修复写入的参数还在吗?
#    2) 相机现在能不能用?
#    3) 修复之后还掉过线吗?(看最后移除时刻 + 坏节点 + 事件日志)
# ============================================================

$ErrorActionPreference = 'Continue'
$enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'

function Head($t) { Write-Host ""; Write-Host "===== $t =====" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "  [X]  $t" -ForegroundColor Red }
function Info($t) { Write-Host "  $t" -ForegroundColor Gray }

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " 摄像头修复复查 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

$boot = $null
try { $boot = [datetime]((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime) } catch { }
Head "运行环境"
Info "本次开机时刻: $boot"

# ---------- 1. 相机在场与状态 ----------
Head "1) 相机现在能不能用"
$cam = pnputil /enum-devices /class Camera 2>&1
$inst = $cam | Select-String -Pattern 'VID_174F'
if ($inst) {
    $started = ($cam | Select-String -Pattern 'Status:\s+Started|状态:\s*已启动').Count
    $desc = ($cam | Select-String -Pattern 'Device Description|设备描述' | ForEach-Object { $_.Line.Trim() -replace 'Device Description:\s*','' }) -join ' + '
    if ($started -ge 1) { Ok "在位且已启动: $desc" } else { Warn "在位但未启动: $desc" }
} else {
    Bad "相机不在总线上"
}

# ---------- 2. 写入的参数是否还在 ----------
Head "2) 修复参数是否保留"
$svcOk = 0
foreach ($svc in @('USBHUB3','usbhub')) {
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name DisableSelectiveSuspend -ErrorAction SilentlyContinue).DisableSelectiveSuspend
    if ($v -eq 1) { Ok "$svc DisableSelectiveSuspend = 1 (持久开关, 已生效)"; $svcOk++ }
    else { Warn "$svc DisableSelectiveSuspend = $v (未设置)" }
}
if ($svcOk -eq 0) { Bad "全局 hub 选择性挂起开关丢失了 —— 需要重跑 repair-camera.cmd" }

$retryKept = 0
foreach ($k in (Get-ChildItem $enumRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'VID_174F' })) {
    foreach ($i in @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)) {
        $dp = Join-Path $i.PSPath 'Device Parameters'
        if (Test-Path $dp) {
            $x = Get-ItemProperty $dp -ErrorAction SilentlyContinue
            $line = "{0}: SuspendEnabled={1} IdleD3={2} Retry={3} 运行时挂起={4}" -f `
                $i.PSChildName, $x.SelectiveSuspendEnabled, $x.AllowIdleIrpInD3, $x.EnumerationRetryCount, $x.DeviceSelectiveSuspended
            if ($x.SelectiveSuspendEnabled -eq 0 -and $x.AllowIdleIrpInD3 -eq 0) { Ok $line; if ($x.EnumerationRetryCount -ge 1) { $retryKept++ } }
            else { Warn $line }
        }
    }
}

# ---------- 3. 修好之后还掉过线吗 ----------
Head "3) 修复之后还掉过线吗"
$lastRemoval = $null
foreach ($k in (Get-ChildItem $enumRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'VID_174F' })) {
    foreach ($i in @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)) {
        $x = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
        if ($x.LastRemovalDate) {
            Info ("  {0} 最后移除: {1}" -f $i.PSChildName, $x.LastRemovalDate)
            $d = $null
            try { $d = [datetime]::Parse(($x.LastRemovalDate).ToString()) } catch { }
            if ($d -and (-not $lastRemoval -or $d -gt $lastRemoval)) { $lastRemoval = $d }
        }
        if ($x.LastArrivalDate) { Info ("  {0} 最后到场: {1}" -f $i.PSChildName, $x.LastArrivalDate) }
    }
}
if ($lastRemoval -and $boot -and ($lastRemoval -gt $boot)) {
    Bad "本次开机之后相机又被移除过 ($lastRemoval) —— 故障仍在复发"
} elseif ($lastRemoval) {
    Ok "本次开机后未再掉线 (最后移除时间早于本次开机)"
} else {
    Info "没有移除记录可参考"
}

$bad = pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_0000&PID_0002'
if ($bad) { Bad "又出现了描述符请求失败的占位节点 —— 掉线已复发" } else { Ok "没有坏节点 (VID_0000&PID_0002)" }

$ks = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-f976-4f5b-9b55-b94699c46e44}'
$ksn = @(Get-ChildItem $ks -ErrorAction SilentlyContinue).Count
Info "内核流接口数 = $ksn (2 = RGB+IR 都能被应用调用)"

# ---------- 4. 事件日志 ----------
Head "4) 最近的 USB/PnP 事件(仅相机相关)"
try {
    $ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddHours(-24)} -ErrorAction Stop |
          Where-Object { $_.Message -match 'VID_174F|VID_0000' } |
          Select-Object -First 10 TimeCreated,Id,ProviderName,@{n='M';e={($_.Message -split "`n")[0]}}
    if ($ev) { $ev | ForEach-Object { Info ("  {0} [{1}] {2}" -f $_.TimeCreated,$_.Id,$_.M) } }
    else { Info "  24 小时内没有相机相关事件(正常)" }
} catch { Info "  事件日志读取失败: $($_.Exception.Message)" }

# ---------- 结论 ----------
Head "结论"
if ($inst -and $svcOk -gt 0 -and -not $bad) {
    Ok "相机可用, 且当前没有掉线痕迹。继续用 watch-camera.cmd 观察即可。"
} elseif (-not $inst -or $bad) {
    Bad "相机又掉了 —— 请把本窗口输出和 incidents\ 里的现场文件保留下来。"
    Info "若已排除电源/枚举因素, 下一步做 fold-test.cmd 折角测试判定排线。"
} else {
    Warn "参数不完整, 建议重跑 repair-camera.cmd 后再完全关机开机。"
}
Write-Host ""
Read-Host "按回车退出"
