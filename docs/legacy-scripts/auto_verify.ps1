# ============================================================
#  auto_verify.ps1 — 开机自动复查摄像头（静默版）
#
#  设计:
#    - 开机(登录)时自动运行, 不弹窗口、不等回车
#    - 每次结果追加到 auto-verify-log.txt, 同时覆盖写 last-verify.txt
#    - 只有【发现问题】时才弹窗提醒; 正常时完全静默
#    - 手动运行加 -Force 可强制弹窗(用于测试)
#    - 手动运行加 -Show  可把结果打到控制台
#
#  安装: 启动文件夹里的 cam-auto-verify.cmd 负责调用本脚本
# ============================================================

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Show
)

$ErrorActionPreference = 'Continue'
$dir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logAll = Join-Path $dir 'auto-verify-log.txt'
$latest = Join-Path $dir 'last-verify.txt'
$now    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Emit { param([string]$s) if ($Show) { Write-Host $s } }

# ---------- 采集 ----------
$problems = New-Object System.Collections.Generic.List[string]
$facts    = New-Object System.Collections.Generic.List[string]

# 开机时刻 / 已运行时长
$boot = $null
try { $boot = [datetime]((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime) } catch { }
$uptime = ''
if ($boot) { $u = (Get-Date) - $boot; $uptime = ('{0}h{1}m' -f [int]$u.TotalHours, $u.Minutes) }

# 1) 相机在不在、能不能用
$cam = pnputil /enum-devices /class Camera 2>&1
$hit = $cam | Select-String -Pattern 'VID_174F'
$started = ($cam | Select-String -Pattern 'Status:\s+Started|状态:\s*已启动').Count
$names = (($cam | Select-String -Pattern 'Device Description|设备描述' | ForEach-Object { ($_.Line -replace '.*(Device Description|设备描述):\s*','').Trim() }) -join '+')
if (-not $hit) {
    $problems.Add('相机不在总线上')
    $facts.Add('相机=缺失')
} else {
    $facts.Add("相机=$names")
    if ($started -lt 1) { $problems.Add('相机在位但未启动') }
}

# 2) 坏节点（描述符请求失败 = 又掉线了）
$bad = pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_0000&PID_0002'
if ($bad) {
    $problems.Add('出现坏节点 VID_0000&PID_0002')
    $facts.Add('坏节点=有')
} else {
    $facts.Add('坏节点=无')
}

# 3) 修复开关是否丢失
$sw = @()
foreach ($svc in @('USBHUB3','usbhub')) {
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name DisableSelectiveSuspend -ErrorAction SilentlyContinue).DisableSelectiveSuspend
    if ($v -eq 1) { $sw += '1' } else { $sw += '0'; $problems.Add("$svc 的 DisableSelectiveSuspend 丢失") }
}
$facts.Add('开关=' + ($sw -join '/'))

# 4) 内核流接口
$ks = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-f976-4f5b-9b55-b94699c46e44}'
$ksn = @(Get-ChildItem $ks -ErrorAction SilentlyContinue).Count
$facts.Add("接口=$ksn")
if ($ksn -lt 2 -and $hit) { $problems.Add('内核流接口不足 2 个') }

# 5) 分辨率档位（检测"模糊"降级态）
$ffq = $null
$cmdf = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($cmdf) { $ffq = $cmdf.Source }
if (-not $ffq) {
    $root = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $root) {
        $hit2 = @(Get-ChildItem $root -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue -Depth 6 | Select-Object -First 1)
        if ($hit2.Count -gt 0) { $ffq = $hit2[0].FullName }
    }
}
if ($ffq -and $camPresent) {
    try {
        $lo = & $ffq -hide_banner -f dshow -list_options true -i video="Integrated Camera" 2>&1
        $bindFail = [bool]($lo | Select-String -Pattern 'Unable to BindToObject|Could not find video device')
        if ($bindFail) {
            $facts.Add('格式档=设备忙未测')
        } else {
            $nfmt = @($lo | Select-String -Pattern 'pixel_format').Count
            $has1080 = @($lo | Select-String -Pattern '1920x1080').Count -gt 0
            $facts.Add("格式档=$nfmt")
            if ($nfmt -lt 5 -or -not $has1080) {
                $problems.Add("相机被降级（仅 $nfmt 档格式, 含1080p=$has1080）→ 现象就是画面模糊")
            }
        }
    } catch { }
} elseif ($camPresent) {
    $facts.Add('格式档=未测(无ffmpeg)')
}

# 6) USB 选择性暂停是否被电源计划复位（这是 10-11 复发的直接原因）
try {
    $sub = '2a737441-1930-4402-8d77-b2bebba308a3'
    $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    $pq = powercfg /query SCHEME_CURRENT $sub $set 2>&1
    $acLine = ($pq | Select-String -Pattern '当前交流|Current AC' | Select-Object -First 1)
    $acv = ''
    if ($acLine) { $acv = ($acLine.Line -replace '.*:\s*', '').Trim() }
    $facts.Add("USB选择性暂停=$acv")
    if ($acv -match '0x0*1$') {
        powercfg /setacvalueindex SCHEME_CURRENT $sub $set 0 2>&1 | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 0 2>&1 | Out-Null
        powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
        $facts.Add('选择性暂停曾被复位, 已自动改回禁用')
    }
} catch { }

# ---------- 汇总 ----------
$status = if ($problems.Count -eq 0) { 'OK' } else { 'ALERT' }
$head   = "[{0}] {1,-5} 开机={2} 运行={3} | {4}" -f $now, $status, $(if ($boot) { $boot.ToString('MM-dd HH:mm') } else { '?' }), $uptime, ($facts -join ' | ')
$detail = if ($problems.Count -gt 0) { '        问题: ' + ($problems -join '; ') } else { '' }

Emit $head
if ($detail) { Emit $detail }

# 日志（追加，只留最近 300 行避免无限增长）
try {
    Add-Content -LiteralPath $logAll -Value $head -Encoding UTF8
    if ($detail) { Add-Content -LiteralPath $logAll -Value $detail -Encoding UTF8 }
    $c = @(Get-Content -LiteralPath $logAll -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($c.Count -gt 300) { $c[-300..-1] | Set-Content -LiteralPath $logAll -Encoding UTF8 }
} catch { }

# 人类可读快照（覆盖）
try {
    $snap = @(
        "摄像头开机复查 —— $now"
        "状态: $(if ($status -eq 'OK') { '正常' } else { '异常' })"
        "开机时刻: $boot   已运行: $uptime"
        "明细: " + ($facts -join ' | ')
    )
    if ($problems.Count -gt 0) { $snap += ("问题: " + ($problems -join '; ')) }
    $snap += ''
    $snap += '（本文件每次开机自动覆盖；历史记录见 auto-verify-log.txt）'
    $snap | Set-Content -LiteralPath $latest -Encoding UTF8
} catch { }

# ---------- 异常时自动抓现场(免手动) ----------
$incPath = ''
if ($problems.Count -gt 0) {
    try {
        $incDir = Join-Path $dir 'incidents'
        if (-not (Test-Path $incDir)) { New-Item -ItemType Directory -Path $incDir -Force | Out-Null }
        $incPath = Join-Path $incDir ("auto_incident_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $s2 = @()
        $s2 += "===== 开机自动复查发现异常：现场快照 ====="
        $s2 += "时刻: $now   开机: $boot   已运行: $uptime"
        $s2 += "问题: " + ($problems -join '; ')
        $s2 += "明细: " + ($facts -join ' | ')
        $s2 += ""
        $s2 += "----- 相机类设备 -----"
        $s2 += (pnputil /enum-devices /class Camera 2>&1 | Out-String)
        $s2 += "----- VID_174F 全部节点 -----"
        $s2 += (pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_174F' | Out-String)
        $s2 += "----- 坏节点 VID_0000&PID_0002 -----"
        $s2 += (pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_0000&PID_0002' -Context 0,6 | Out-String)
        $s2 += "----- 相机电源参数 -----"
        foreach ($kk in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'VID_174F' })) {
            foreach ($ii in @(Get-ChildItem $kk.PSPath -ErrorAction SilentlyContinue)) {
                $dp2 = Join-Path $ii.PSPath 'Device Parameters'
                if (Test-Path $dp2) {
                    $x2 = Get-ItemProperty $dp2 -ErrorAction SilentlyContinue
                    $s2 += ("  {0}: SuspendEnabled={1} IdleD3={2} Retry={3} RuntimeSuspended={4}" -f $ii.PSChildName, $x2.SelectiveSuspendEnabled, $x2.AllowIdleIrpInD3, $x2.EnumerationRetryCount, $x2.DeviceSelectiveSuspended)
                }
            }
        }
        $s2 += "----- 最近 15 分钟系统事件(USB/PnP) -----"
        try {
            $s2 += (Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction Stop |
                    Where-Object { $_.ProviderName -match 'PnP|USB|Wdf|Hub' } |
                    Select-Object -First 20 TimeCreated,Id,ProviderName | Format-Table -AutoSize | Out-String)
        } catch { $s2 += "(事件日志读取失败)" }
        $s2 | Set-Content -LiteralPath $incPath -Encoding UTF8
    } catch { }
}

# ---------- 异常弹窗 ----------
if ($problems.Count -gt 0 -or $Force) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if ($problems.Count -gt 0) {
            $t = '摄像头开机复查：发现问题'
            $m = "时间: $now`n开机: $boot`n`n" + ($problems -join "`n") + "`n`n明细: " + ($facts -join ' | ') +
                 "`n`n建议: 右键以管理员运行 camera-fix\watch-camera.cmd 抓现场；" +
                 "`n若已多次复发，改用 fold-test.cmd 折角测试后报修。"
            $icon = 'Warning'
        } else {
            $t = '摄像头开机复查'
            $m = "时间: $now`n开机: $boot`n`n一切正常。`n`n" + ($facts -join ' | ')
            $icon = 'Information'
        }
        [System.Windows.Forms.MessageBox]::Show($m, $t, 'OK', $icon) | Out-Null
    } catch { }
}

if ($Show) { Write-Host "" ; Write-Host "日志: $logAll" ; Write-Host "快照: $latest" }
exit 0
