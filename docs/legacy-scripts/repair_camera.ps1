# ============================================================
#  repair_camera.ps1 — 内置摄像头「运行中掉线 / 描述符请求失败」定向修复
#  机型: ThinkBook 16 G7 AHP (21MU) / Realtek DMFT 双摄 (VID_174F&PID_1820)
#
#  修复依据 (2026-10-07 二次诊断):
#    1) 相机三个设备实例的 DeviceSelectiveSuspended 全为 1
#       -> 空闲即被挂起, 唤醒(D0)失败时设备直接从总线消失,
#          留下 USB\VID_0000&PID_0002 (描述符请求失败) 占位节点
#    2) EnumerationRetryCount = 0  -> 枚举失败一次就放弃, 没有重试
#    3) 之前关的是「全局 / hub 端口」选择性暂停, 设备自身开关从未关过
#
#  用法 (本脚本必须管理员运行, 用 repair-camera.cmd 双击即可):
#    repair-camera.cmd                 应用修复(默认)
#    repair-camera.cmd -Reinstall      修复 + 移除相机设备节点重新枚举
#    repair-camera.cmd -Restore        回滚到修复前的备份
#    repair-camera.cmd -DiagOnly       只看现状, 不改任何东西
# ============================================================

[CmdletBinding()]
param(
    [switch]$Reinstall,
    [switch]$Restore,
    [switch]$DiagOnly
)

$ErrorActionPreference = 'Continue'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logPath   = Join-Path $scriptDir 'repair_camera_log.txt'
$bakDir    = Join-Path $scriptDir 'backup'
$stamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$log       = New-Object System.Collections.Generic.List[string]

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $log.Add($Text)
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 0. 权限 ----------
Say "=====================================================" Cyan
Say " 摄像头定向修复 (设备级选择性挂起 + 枚举重试)" Cyan
Say " $stamp" Cyan
Say "=====================================================" Cyan
Say ""

if (-not (Test-Admin)) {
    Say "[!] 未以管理员运行 —— 无法修改 HKLM 与重启设备。" Red
    Say "    请改用 repair-camera.cmd 双击运行(会自动弹 UAC)。" Red
    $log | Set-Content -LiteralPath $logPath -Encoding UTF8
    Read-Host "按回车退出"
    exit 1
}
Say "[OK] 已以管理员权限运行。" Green

if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }

$enumRoot  = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
$camRegex  = 'VID_174F'
$badRegex  = 'VID_0000&PID_0002'
$powerVals = @{
    'SelectiveSuspendEnabled'        = 0   # 不允许系统为省电关闭该设备
    'AllowIdleIrpInD3'               = 0   # 禁止空闲进入 D3
    'EnhancedPowerManagementEnabled' = 0   # 关闭增强电源管理
    'EnumerationRetryCount'          = 3   # 枚举失败重试 3 次(原为 0)
}

function Get-CamKeys {
    Get-ChildItem $enumRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match $camRegex -or $_.PSChildName -match $badRegex }
}

# ---------- 1. 现状 ----------
Say ""
Say "---------- 修复前状态 ----------" White
$camKeys = @(Get-CamKeys)
if ($camKeys.Count -eq 0) {
    Say "  [!] 注册表中找不到 VID_174F 相机节点。" Yellow
} else {
    foreach ($k in $camKeys) {
        $instances = @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)
        if ($instances.Count -eq 0) { $instances = @($k) }
        foreach ($inst in $instances) {
            $dp = Join-Path $inst.PSPath 'Device Parameters'
            $cur = if (Test-Path $dp) { Get-ItemProperty $dp -ErrorAction SilentlyContinue } else { $null }
            Say ("  {0}" -f $inst.PSChildName)
            foreach ($v in $powerVals.Keys) {
                $val = if ($cur -and $null -ne $cur.$v) { $cur.$v } else { '(未设置)' }
                Say ("      {0,-30} = {1}" -f $v, $val)
            }
        }
    }
}

$present = pnputil /enum-devices /class Camera 2>&1 | Select-String -Pattern 'VID_174F'
Say ""
if ($present) { Say "  相机当前: 在场" Green } else { Say "  相机当前: 不在总线上" Red }

# ---------- 2. 回滚模式 ----------
if ($Restore) {
    Say ""
    Say "---------- 回滚模式 ----------" White
    $regs = @(Get-ChildItem $bakDir -Filter '*.reg' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($regs.Count -eq 0) {
        Say "  [!] 没有找到备份 .reg 文件, 无法回滚。" Red
    } else {
        $target = $regs[0].FullName
        Say "  使用备份: $target"
        $out = reg import "$target" 2>&1
        Say ("  reg import: " + ($out -join ' '))
        Say "  [OK] 已回滚。建议重启电脑生效。" Green
    }
    Say ""
    Say "日志: $logPath"
    $log | Set-Content -LiteralPath $logPath -Encoding UTF8
    Read-Host "按回车退出"
    exit 0
}

if ($DiagOnly) {
    Say ""
    Say "[DiagOnly] 只诊断, 未做任何修改。"
    $log | Set-Content -LiteralPath $logPath -Encoding UTF8
    Read-Host "按回车退出"
    exit 0
}

# ---------- 3. 备份 ----------
Say ""
Say "---------- 备份 ----------" White
$bakFile = Join-Path $bakDir ("usb_vid174f_backup_{0}.reg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$bak = reg export 'HKLM\SYSTEM\CurrentControlSet\Enum\USB' "$bakFile" /y 2>&1
if (Test-Path $bakFile) {
    Say "  [OK] 注册表已备份: $bakFile" Green
} else {
    Say "  [!] reg export 失败: $($bak -join ' ')" Yellow
    Say "      (不阻断修复, 但回滚将不可用)" Yellow
}

# ---------- 4. 应用修复 ----------
Say ""
Say "---------- [1/3] 关闭设备级选择性挂起 / 打开枚举重试 ----------" White
$changed = 0
foreach ($k in Get-CamKeys) {
    $instances = @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)
    if ($instances.Count -eq 0) { $instances = @($k) }
    foreach ($inst in $instances) {
        $dp = Join-Path $inst.PSPath 'Device Parameters'
        if (-not (Test-Path $dp)) {
            try { New-Item -Path $dp -Force | Out-Null } catch { Say "      [!] 无法创建 $dp" Yellow; continue }
        }
        foreach ($v in $powerVals.Keys) {
            try {
                New-ItemProperty -Path $dp -Name $v -Value $powerVals[$v] -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                Say ("      [OK] {0,-30} -> {1}" -f $v, $powerVals[$v]) Green
                $changed++
            } catch {
                Say ("      [!] {0} 写入失败: {1}" -f $v, $_.Exception.Message) Yellow
            }
        }
    }
}
if ($changed -eq 0) { Say "      [!] 没有写入任何值, 请检查相机节点是否存在。" Yellow }

Say ""
Say "---------- [2/3] 全局 USB 选择性挂起兜底 ----------" White
try {
foreach ($svc in @('USBHUB3','usbhub')) {
    $sk = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (Test-Path $sk) {
        New-ItemProperty -Path $sk -Name 'DisableSelectiveSuspend' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Say "      [OK] $svc DisableSelectiveSuspend = 1" Green
    }
}
    Say "      [OK] DisableSelectiveSuspend = 1" Green
} catch {
    Say "      [!] 写入失败: $($_.Exception.Message)" Yellow
}

# ---------- 5. 重新枚举 ----------
Say ""
Say "---------- [3/3] 让设置生效 ----------" White

# 先清掉「描述符请求失败」的占位节点, 免得它占着端口影响重新枚举
$badKeys = @(Get-ChildItem $enumRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match $badRegex })
foreach ($k in $badKeys) {
    foreach ($inst in @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)) {
        $full = "USB\$($k.PSChildName)\$($inst.PSChildName)"
        $o = pnputil /remove-device "$full" 2>&1
        Say ("      清理占位节点 {0}: {1}" -f $inst.PSChildName, (($o | Select-Object -First 1) -join ''))
    }
}
if ($badKeys.Count -eq 0) { Say "      无占位坏节点需要清理。" }

if ($Reinstall) {
    Say "      模式: -Reinstall, 移除相机设备节点并重新扫描(驱动包保留)"
    foreach ($k in Get-CamKeys) {
        $instances = @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)
        if ($instances.Count -eq 0) { $instances = @($k) }
        foreach ($inst in $instances) {
            $full = "USB\$($k.PSChildName)\$($inst.PSChildName)"
            $o = pnputil /remove-device "$full" 2>&1
            Say ("      remove-device {0}: {1}" -f $inst.PSChildName, (($o | Select-Object -First 1) -join ''))
        }
    }
}

# 重启承载相机的 USB 根集线器(等效拔插)
$parent = $null
# 沿 PnP 设备树向上找真正的根集线器实例 ID(不能用 ParentIdPrefix, 那只是前缀)
try {
    $cams = @(Get-PnpDevice -Class Camera -ErrorAction Stop | Where-Object { $_.InstanceId -match 'VID_174F' })
    foreach ($d in $cams) {
        $cur = $d
        for ($i = 0; $i -lt 8 -and $cur; $i++) {
            if ($cur.InstanceId -match '^USB\\ROOT_HUB30') { $parent = $cur.InstanceId; break }
            $par = ($cur | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
            if (-not $par) { break }
            $cur = Get-PnpDevice -InstanceId $par -ErrorAction SilentlyContinue
        }
        if ($parent) { break }
    }
} catch { }
if (-not $parent) {
    $rh = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\ROOT_HUB30' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($rh) { $parent = "USB\ROOT_HUB30\$($rh.PSChildName)" }
}

# 先重启相机复合设备(精准, 副作用小), 让刚写入的电源参数真正生效
$compId = $null
foreach ($k in Get-CamKeys) {
    if ($k.PSChildName -match 'VID_174F&PID_1820$') {
        $ci = Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ci) { $compId = "USB\$($k.PSChildName)\$($ci.PSChildName)" }
    }
}
if ($compId) {
    $rc = pnputil /restart-device "$compId" 2>&1
    $r1 = ($rc | Select-Object -Last 2) -join " "
    Say "      重启相机复合设备 $compId : $r1"
    Start-Sleep -Seconds 3
}

if ($parent) {
    Say "      目标根集线器: $parent"
    $r = pnputil /restart-device "$parent" 2>&1
    $r2 = ($r | Select-Object -Last 3) -join " "
    Say "      restart-device: $r2"
} else {
    Say "      [!] 未能定位根集线器, 跳过(完全关机同样生效)。" Yellow
}

Start-Sleep -Seconds 3
pnputil /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 4

# ---------- 6. 验证 ----------
Say ""
Say "---------- 修复后验证 ----------" White
$now = pnputil /enum-devices /class Camera 2>&1
if ($now | Select-String -Pattern 'VID_174F') {
    Say "  [OK] 相机已回到总线。" Green
    $now | Select-String -Pattern 'Instance ID|设备 ID|Device Description|设备描述|Status|状态' | ForEach-Object { Say ("    " + $_.Line.Trim()) }
} else {
    Say "  [--] 相机仍未出现 —— 请完全关机(非重启)后再开机一次。" Yellow
}
$stillBad = pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_0000&PID_0002'
if ($stillBad) { Say "  [!] 仍存在描述符请求失败的占位节点(下次开机应消失)。" Yellow }

Say ""
Say "---------- 复查写入结果 ----------" White
foreach ($k in Get-CamKeys) {
    $instances = @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)
    if ($instances.Count -eq 0) { $instances = @($k) }
    foreach ($inst in $instances) {
        $dp = Join-Path $inst.PSPath 'Device Parameters'
        if (Test-Path $dp) {
            $cur = Get-ItemProperty $dp -ErrorAction SilentlyContinue
            $bits = foreach ($v in $powerVals.Keys) { "$v=$($cur.$v)" }
            Say ("  {0}: {1}" -f $inst.PSChildName, ($bits -join ', '))
        }
    }
}

Say ""
Say ">>> 下一步: 完全关机(菜单关机, 不要选重启), 等 10 秒再开机。" Cyan
Say "    开机后双击 watch-camera.cmd 让它持续盯着, 下次掉线会自动抓现场。" Cyan
Say ""
Say "日志已写入: $logPath"
$log | Set-Content -LiteralPath $logPath -Encoding UTF8

Read-Host "按回车退出"
