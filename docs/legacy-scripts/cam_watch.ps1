# ============================================================
#  cam_watch.ps1 — 摄像头实时守护 + 掉线现场抓取 (+ 折角测试)
#
#  作用:
#    - 每 N 秒检查内置相机是否在总线上
#    - 一旦掉线: 记录精确时刻, 自动抓现场(设备树 / 坏节点 / 事件日志)
#                可选自动重启根集线器把相机救回来
#    - -FoldTest 模式: 边开合屏幕边按键标注角度, 用来判定排线故障
#
#  用法:
#    watch-camera.cmd              普通守护(免管理员, 只能看不能救)
#    watch-camera.cmd -AutoFix     守护 + 掉线自动救回(需管理员)
#    fold-test.cmd                 折角测试
#
#  退出: Ctrl+C 或 折角模式下按 Q
# ============================================================

[CmdletBinding()]
param(
    [int]$Interval = 5,
    [switch]$AutoFix,
    [switch]$FoldTest,
    [int]$Minutes = 0
)

$ErrorActionPreference = 'Continue'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$stamp0    = Get-Date -Format 'yyyyMMdd_HHmmss'
$mode      = if ($FoldTest) { 'fold' } else { 'watch' }
$logPath   = Join-Path $scriptDir ("cam_{0}_{1}.log" -f $mode, $stamp0)
$incDir    = Join-Path $scriptDir 'incidents'
if (-not (Test-Path $incDir)) { New-Item -ItemType Directory -Path $incDir -Force | Out-Null }

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line -ForegroundColor $Color
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 相机状态探测(双通道, 互为兜底) ----------
function Get-CamState {
    try {
        $d = @(Get-PnpDevice -Class Camera -ErrorAction Stop | Where-Object { $_.InstanceId -match 'VID_174F' -and $_.Present })
        if ($d.Count -gt 0) {
            $ok = @($d | Where-Object { $_.Status -eq 'OK' })
            return New-Object psobject -Property @{
                Present = $true
                Ok      = ($ok.Count -gt 0)
                Names   = (($d | ForEach-Object { $_.FriendlyName }) -join ' + ')
                Source  = 'PnP'
            }
        }
    } catch { }

    $out = pnputil /enum-devices /class Camera 2>&1
    $hit = $out | Select-String -Pattern 'VID_174F'
    if ($hit) {
        $names = ($out | Select-String -Pattern 'Device Description|设备描述' | ForEach-Object { $_.Line.Trim() }) -join ' + '
        $ok = ($out | Select-String -Pattern 'Status:\s+Started|状态:\s*已启动').Count -gt 0
        return New-Object psobject -Property @{ Present = $true; Ok = $ok; Names = $names; Source = 'pnputil' }
    }
    return New-Object psobject -Property @{ Present = $false; Ok = $false; Names = ''; Source = 'pnputil' }
}

function Get-BadNode {
    $o = pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_0000&PID_0002'
    if ($o) { return ($o | Select-Object -First 1).Line.Trim() }
    return ''
}

# ---------- 掉线现场抓取 ----------
function Capture-Incident {
    param([string]$Tag, [string]$Angle = '')
    $f = Join-Path $incDir ("incident_{0}_{1}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Tag)
    $sb = New-Object System.Collections.Generic.List[string]
    $sb.Add("===== 相机掉线现场 =====")
    $sb.Add("时刻     : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $sb.Add("标签     : $Tag")
    if ($Angle) { $sb.Add("掉线时屏幕角度 : $Angle") }
    $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
    $sb.Add("开机时刻 : $boot")
    $sb.Add("")
    $sb.Add("----- 相机类设备 -----")
    $sb.Add((pnputil /enum-devices /class Camera 2>&1 | Out-String))
    $sb.Add("----- VID_174F 全部节点 -----")
    $sb.Add((pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_174F' | Out-String))
    $sb.Add("----- 坏节点 VID_0000&PID_0002 -----")
    $sb.Add((pnputil /enum-devices 2>&1 | Select-String -Pattern 'VID_0000&PID_0002' -Context 0,6 | Out-String))
    $sb.Add("----- 内核流接口数量(0=真的没了, >0=接口还残着) -----")
    $ks = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-f976-4f5b-9b55-b94699c46e44}'
    $sb.Add("接口数 = " + @(Get-ChildItem $ks -ErrorAction SilentlyContinue).Count)
    $sb.Add("----- 相机电源参数 -----")
    foreach ($k in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'VID_174F' })) {
        foreach ($inst in @(Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)) {
            $dp = Join-Path $inst.PSPath 'Device Parameters'
            if (Test-Path $dp) {
                $p = Get-ItemProperty $dp -ErrorAction SilentlyContinue
                $sb.Add(("  {0}: SelectiveSuspendEnabled={1} AllowIdleIrpInD3={2} DeviceSelectiveSuspended={3} EnumerationRetryCount={4}" -f `
                    $inst.PSChildName, $p.SelectiveSuspendEnabled, $p.AllowIdleIrpInD3, $p.DeviceSelectiveSuspended, $p.EnumerationRetryCount))
            }
        }
    }
    $sb.Add("")
    $sb.Add("----- 最近 15 分钟 系统事件(USB/PnP) -----")
    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction Stop |
              Where-Object { $_.ProviderName -match 'PnP|USB|Wdf|Hub' } |
              Select-Object -First 25 TimeCreated,Id,ProviderName,@{n='M';e={($_.Message -split "`n")[0]}}
        $sb.Add(($ev | Format-Table -AutoSize | Out-String -Width 200))
    } catch { $sb.Add("(事件日志读取失败: $($_.Exception.Message))") }
    $sb | Set-Content -LiteralPath $f -Encoding UTF8
    return $f
}

# ---------- 自动救回 ----------
function Invoke-AutoFix {
    if (-not (Test-Admin)) { Write-Line "  [AutoFix] 需要管理员, 跳过自动恢复。" Yellow; return }
    Write-Line "  [AutoFix] 正在重启承载相机的根集线器..." Yellow
    $parent = 'USB\ROOT_HUB30\5&8b8e61a&0&0'
    $k = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue |
         Where-Object { $_.PSChildName -match 'VID_174F' } | Select-Object -First 1
    if ($k) {
        $inst = Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($inst) {
            $p = Get-ItemProperty $inst.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.ParentIdPrefix) { $parent = $p.ParentIdPrefix }
        }
    }
    pnputil /restart-device "$parent" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    pnputil /scan-devices 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $s = Get-CamState
    if ($s.Present -and $s.Ok) { Write-Line "  [AutoFix] 已救回: $($s.Names)" Green }
    else { Write-Line "  [AutoFix] 仍未恢复, 需完全关机再开机。" Red }
}

# ---------- 主流程 ----------
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
if ($FoldTest) { Write-Host " 摄像头折角测试 (判定排线 / 模组)" -ForegroundColor Cyan }
else { Write-Host " 摄像头实时守护 (掉线即抓现场)" -ForegroundColor Cyan }
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host (" 间隔: {0}s   自动救回: {1}   管理员: {2}" -f $Interval, $AutoFix, (Test-Admin)) -ForegroundColor Gray
Write-Host (" 日志: {0}" -f $logPath) -ForegroundColor Gray
Write-Host " 退出: Ctrl+C" -ForegroundColor DarkGray
Write-Host ""

Write-Line ("守护启动 | 间隔=${Interval}s | AutoFix=$AutoFix | FoldTest=$FoldTest")

$last      = $null
$drops     = 0
$quit      = $false
$startTime = Get-Date
$angle     = '(未标注)'
$angleMap  = @{ '1' = '合上'; '2' = '30度'; '3' = '60度'; '4' = '90度'; '5' = '120度'; '6' = '全开' }

if ($FoldTest) {
    Write-Host " 操作: 保持本窗口在前台, 慢慢开合屏幕; 每到一个角度按对应数字键标注:" -ForegroundColor Yellow
    Write-Host "       1=合上  2=30度  3=60度  4=90度  5=120度  6=全开    Q=结束" -ForegroundColor Yellow
    Write-Host "       掉线会自动记录当时的角度, 不用手动抄时间。" -ForegroundColor DarkGray
    Write-Host ""
}

while ($true) {
    if ($Minutes -gt 0 -and ((Get-Date) - $startTime).TotalMinutes -ge $Minutes) {
        Write-Line "到达设定时长, 结束守护。" Green
        break
    }

    $s = Get-CamState

    if ($null -eq $last) {
        if ($s.Present) { Write-Line ("初始状态: 在位 | {0}" -f $s.Names) Green }
        else { Write-Line "初始状态: 不在总线上 (等待它出现)" Red }
        $last = $s.Present
    }
    elseif ($last -ne $s.Present) {
        if (-not $s.Present) {
            $bad = Get-BadNode
            $drops++
            Write-Line ("*** 相机掉线! 第 {0} 次 | 当前角度: {1} ***" -f $drops, $angle) Red
            if ($bad) { Write-Line ("    坏节点: {0}" -f $bad) Yellow }
            $f = Capture-Incident -Tag ("drop{0}" -f $drops) -Angle $angle
            Write-Line ("    现场已存: {0}" -f $f) Yellow
            if ($AutoFix) { Invoke-AutoFix }
        } else {
            Write-Line ("相机恢复上线 | {0}" -f $s.Names) Green
            Write-Line ("    当前角度: {0}" -f $angle) Yellow
        }
        $last = $s.Present
    }
    else {
        if ($s.Present -and -not $s.Ok) {
            Write-Line ("警告: 相机在位但状态异常 | {0}" -f $s.Names) Yellow
        }
        elseif ($FoldTest) {
            Write-Host ("[{0}] 监控中 | 角度={1} | 相机正常" -f (Get-Date -Format 'HH:mm:ss'), $angle) -ForegroundColor DarkGray
        }
    }

    if ($FoldTest) {
        try {
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $ch = $key.KeyChar.ToString()
                if ($ch -eq 'q' -or $ch -eq 'Q') { Write-Line "用户按 Q 结束折角测试。" Green; $quit = $true; break }
                if ($angleMap.ContainsKey($ch)) {
                    $angle = $angleMap[$ch]
                    Write-Line ("角度标注 -> {0}" -f $angle) Cyan
                }
            }
        } catch { }
        if ($quit) { break }
        Start-Sleep -Seconds 1
    } else {
        Start-Sleep -Seconds $Interval
    }
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host (" 本次共记录掉线 {0} 次" -f $drops) -ForegroundColor Cyan
if ($drops -gt 0) {
    Write-Host " 掉线现场文件在 incidents\ 目录, 里面含精确时刻与当时的事件日志。" -ForegroundColor Yellow
    Write-Host " 若掉线集中出现在某个开合角度 -> 排线(FPC)故障, 需拆修 / 报修。" -ForegroundColor Yellow
} else {
    Write-Host " 全程未掉线。若之前已跑过 repair-camera.cmd, 说明修复可能已生效。" -ForegroundColor Green
}
Write-Host (" 日志: {0}" -f $logPath) -ForegroundColor Gray
Write-Host "=====================================================" -ForegroundColor Cyan
