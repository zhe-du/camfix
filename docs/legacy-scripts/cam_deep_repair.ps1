# =====================================================================
#  cam_deep_repair.ps1  -  深度修复（不触碰任何电源设置）
#  适用：相机完全不在场 / 重启根集线器无效
#  步骤：清幽灵节点 -> 重扫 -> 重启根集线器 -> 仍无则循环 xHCI 控制器
#  说明：全程只动设备枚举，不改 S0 / 睡眠 / 休眠 / WOL
# =====================================================================

$ErrorActionPreference = 'Continue'
$logPath = Join-Path $PSScriptRoot 'deep_repair_log.txt'
$script:L = New-Object System.Collections.ArrayList
function Say([string]$m, $c) { if ($c) { Write-Host $m -ForegroundColor $c } else { Write-Host $m }; [void]$script:L.Add($m) }
function Save() { Set-Content -Path $logPath -Value $script:L -Encoding UTF8 }
function HasCam() {
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Class -in @('Camera','Image') -and $_.Status -eq 'OK' }
    return ($null -ne $d -and @($d).Count -gt 0)
}
function ShowCam($tag) {
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Class -in @('Camera','Image') }
    if ($d) { foreach ($x in $d) { Say ("  [$tag] {0} | {1}" -f $x.Status, $x.FriendlyName) } }
    else { Say "  [$tag] 相机不在场" }
}

Say "====================================================="
Say " 摄像头 深度修复（不修改任何电源设置）"
Say (" " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say "====================================================="
Say ""

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say "[失败] 需要管理员权限" 'Red'; Save; exit 1
}
Say "[OK] 管理员权限已就绪"
Say ""

Say "---------- 修复前 ----------"
ShowCam '前'
Say ""

# 1. 清幽灵相机节点
Say "[1/5] 清理幽灵相机节点 ..."
$stale = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\VID_174F&PID_1820*' }
foreach ($s in $stale) { Say ("      移除 " + $s.InstanceId); & pnputil.exe /remove-device $s.InstanceId 2>&1 | Out-Null }
if (-not $stale) { Say "      (无)" }
Start-Sleep -Seconds 2

# 2. 清占位坏节点
Say "[2/5] 清理「设备描述符请求失败」占位节点 ..."
$bad = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\VID_0000&PID_0002*' }
foreach ($b in $bad) { Say ("      移除 " + $b.InstanceId); & pnputil.exe /remove-device $b.InstanceId 2>&1 | Out-Null }
if (-not $bad) { Say "      (无)" }
Start-Sleep -Seconds 1

# 3. 重新扫描
Say "[3/5] 重新扫描硬件 ..."
& pnputil.exe /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 6
ShowCam '扫后'
if (HasCam) { Say ""; Say ">>> 结果: 相机已恢复，应用可正常调用。" 'Green'; Save; exit 0 }

# 4. 重启根集线器
Say "[4/5] 重启相机所在的 USB 根集线器 ..."
$hub = 'USB\ROOT_HUB30\5&8b8e61a&0&0'
& pnputil.exe /restart-device $hub 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    try { Disable-PnpDevice -InstanceId $hub -Confirm:$false -ErrorAction Stop
          Start-Sleep -Seconds 3
          Enable-PnpDevice  -InstanceId $hub -Confirm:$false -ErrorAction Stop } catch { Say ("      [失败] " + $_.Exception.Message) 'Red' }
}
Start-Sleep -Seconds 6
ShowCam 'hub后'
if (HasCam) { Say ""; Say ">>> 结果: 相机已恢复。" 'Green'; Save; exit 0 }

# 5. 循环 xHCI 控制器（会短暂断开该控制器上所有 USB 设备）
Say "[5/5] 根集线器无效，改为循环 USB xHCI 控制器 ..."
Say "      注意: 该控制器上的 USB 设备会短暂消失约 10 秒（键鼠若为内置不受影响）" 'Yellow'
$xhc = Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'xHCI|eXtensible|可扩展主机' -and $_.Status -eq 'OK' }
if (-not $xhc) { Say "      未找到 xHCI 控制器，跳过" 'Yellow' }
foreach ($x in $xhc) {
    Say ("      循环 " + $x.FriendlyName)
    try {
        Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 5
        Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -ErrorAction Stop
    } catch { Say ("      [失败] " + $_.Exception.Message) 'Red' }
}
Start-Sleep -Seconds 10
& pnputil.exe /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 5

Say ""
Say "---------- 修复后 ----------"
ShowCam '后'
Say ""
if (HasCam) {
    Say ">>> 结果: 相机已恢复。" 'Green'
} else {
    Say ">>> 结果: 仍未恢复。" 'Yellow'
    Say "    软件层已尽力（清节点/重扫/重启集线器/循环控制器）。"
    Say "    下一步建议: 【完全关机 -> 拔电源 -> 长按电源键 30-60 秒 -> 开机】(EC 复位，不改任何设置)"
}
Say ""
Say ("日志: " + $logPath)
Save
