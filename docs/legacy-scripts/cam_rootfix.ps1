# =====================================================================
#  cam_rootfix.ps1  -  Root-cause fix for the intermittent camera dropout
#  Target : Lenovo ThinkBook 16 Gen 7 AHP (21MU), Windows 11 26H2
#  Issue  : Integrated Camera (USB\VID_174F&PID_1820) intermittently fails
#           USB enumeration on the SAME root-hub port, leaving a phantom
#           "Unknown USB Device (Device Descriptor Request Failed)"
#           (USB\VID_0000&PID_0002) and error 0xA00F4244 in the Camera app.
#
#  What this does (all reversible, see -Restore):
#    1. Disables Fast Startup        (stops the USB controller state being
#                                     carried over across shutdowns)
#    2. Disables USB selective suspend on AC and battery
#    3. Removes phantom / failed USB device nodes
#    4. Power-cycles the USB root hub that hosts the camera
#    5. Re-scans and verifies (device status + kernel-streaming interfaces)
#
#  Requires : Administrator
#  Usage    : cam_rootfix.cmd            (normal fix)
#             cam_rootfix.cmd -Deep      (also purge stale camera nodes)
#             cam_rootfix.cmd -Restore   (undo steps 1 and 2)
#  Output   : cam_rootfix_log.txt (next to this script)
# =====================================================================

param(
    [switch]$Deep,
    [switch]$Restore
)

$ErrorActionPreference = 'Continue'
$logPath  = Join-Path $PSScriptRoot 'cam_rootfix_log.txt'
$script:lines = New-Object System.Collections.ArrayList

function Say([string]$msg, $color) {
    if ($color) { Write-Host $msg -ForegroundColor $color } else { Write-Host $msg }
    [void]$script:lines.Add($msg)
}
function Save() { Set-Content -Path $logPath -Value $script:lines -Encoding UTF8 }

Say "====================================================="
Say " 摄像头掉线 根因修复 (USB enumeration root fix)"
Say (" " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say "====================================================="
Say ""

# ------------------------------------------------------------ 0. admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say "[失败] 需要管理员权限运行。" 'Red'
    Save; exit 1
}
Say "[OK] 已以管理员权限运行。"
Say ""

# ------------------------------------------------------- 1. snapshot
Say "---------- 修复前状态 ----------"
$camNow = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
          Where-Object { $_.Class -in @('Camera','Image') }
if ($camNow) {
    foreach ($c in $camNow) { Say ("  相机: [{0}] {1}" -f $c.Status, $c.FriendlyName) }
} else {
    Say "  相机: (当前不在总线上)" 'Yellow'
}
$badNow = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
          Where-Object { $_.Status -ne 'OK' -and $_.InstanceId -like 'USB\*' }
foreach ($b in $badNow) { Say ("  异常USB: [{0}] {1} | {2}" -f $b.Status, $b.FriendlyName, $b.InstanceId) }
Say ("  快速启动 HiberbootEnabled = {0}" -f (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled)
Say ""

$PWR  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$SUB_USB  = '2a737441-1930-4402-8d77-b2bebba308a3'   # USB settings subgroup
$SET_SUSP = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'   # USB selective suspend

if ($Restore) {
    # ---------------------------------------------------- restore mode
    Say "========== 恢复模式 (-Restore) =========="
    Set-ItemProperty $PWR -Name HiberbootEnabled -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Say "[1/2] 快速启动已重新开启 (HiberbootEnabled=1)"
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $SUB_USB $SET_SUSP 1 2>&1 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT $SUB_USB $SET_SUSP 1 2>&1 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
    Say "[2/2] USB 选择性暂停已恢复 (AC/DC = 启用)"
    Say ""
    Say "已恢复为默认设置。"
    Save; exit 0
}

# ------------------------------------------- 2. fix A: fast startup off
Say "[1/4] 关闭「快速启动」..."
try {
    Set-ItemProperty $PWR -Name HiberbootEnabled -Value 0 -Type DWord -Force -ErrorAction Stop
    Say "      [OK] HiberbootEnabled = 0" 'Green'
} catch {
    Say ("      [失败] " + $_.Exception.Message) 'Red'
}
Say ""

# ------------------------------- 3. fix B: usb selective suspend off
Say "[2/4] 关闭「USB 选择性暂停」(AC + 电池)..."
& powercfg.exe /setacvalueindex SCHEME_CURRENT $SUB_USB $SET_SUSP 0 2>&1 | Out-Null
& powercfg.exe /setdcvalueindex SCHEME_CURRENT $SUB_USB $SET_SUSP 0 2>&1 | Out-Null
& powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
Say "      [OK] 已设置为「已禁用」(两个供电场景)" 'Green'
Say ""

# ----------------------------- 4. fix C: purge phantom / failed nodes
Say "[3/4] 清理幽灵 / 枚举失败设备节点..."
$phantom = Get-PnpDevice -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceId -like 'USB\VID_0000&PID_0002*' -or $_.Status -eq 'Error' -and $_.InstanceId -like 'USB\*' }
if ($phantom) {
    foreach ($p in $phantom) {
        Say ("      移除 " + $p.InstanceId)
        & pnputil.exe /remove-device $p.InstanceId 2>&1 | Out-Null
    }
    if (-not $phantom) { Say "      (无)" }
} else {
    Say "      (无可清理节点)"
}
if ($Deep) {
    Say "      -Deep: 额外清理历史相机节点..."
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_174F&PID_1820*' } | ForEach-Object {
            Say ("      移除 " + $_.InstanceId)
            & pnputil.exe /remove-device $_.InstanceId 2>&1 | Out-Null
        }
}
Start-Sleep -Seconds 2
Say ""

# --------------------------- 5. fix D: power-cycle the host root hub
Say "[4/4] 重启相机所在的 USB 根集线器..."
$cam = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like 'USB\VID_174F&PID_1820*' } | Select-Object -First 1
$hub = $null
if ($cam) {
    $parent = (Get-PnpDeviceProperty -InstanceId $cam.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    if ($parent) {
        $hub = (Get-PnpDeviceProperty -InstanceId $parent -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    }
}
if (-not $hub) { $hub = 'USB\ROOT_HUB30\5&8b8e61a&0&0' }
Say ("      目标根集线器: " + $hub)
& pnputil.exe /restart-device $hub 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Say "      pnputil 失败，改用 Disable/Enable-PnpDevice ..."
    try {
        Disable-PnpDevice -InstanceId $hub -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        Enable-PnpDevice  -InstanceId $hub -Confirm:$false -ErrorAction Stop
        Say "      [OK] 集线器已断电重插。" 'Green'
    } catch {
        Say ("      [失败] " + $_.Exception.Message) 'Red'
    }
} else {
    Say "      [OK] 集线器已重启。" 'Green'
}
Start-Sleep -Seconds 4

# ------------------------------------------------- 6. rescan + verify
& pnputil.exe /scan-devices 2>&1 | Out-Null
Start-Sleep -Seconds 5

Say ""
Say "---------- 修复后验证 ----------"
$camAfter = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.Class -in @('Camera','Image') -and $_.Status -eq 'OK' }
if ($camAfter) {
    foreach ($c in $camAfter) { Say ("  [OK] {0}  ({1})" -f $c.FriendlyName, $c.Status) }
} else {
    Say "  [--] 相机未出现在总线上" 'Yellow'
}

# kernel-streaming interface = proof apps can really open the camera
$ksKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-f976-4f5b-9b55-b94699c46e44}'
$ksCam = @()
if (Test-Path $ksKey) {
    $ksCam = Get-ChildItem $ksKey -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -like '*VID_174F*' }
}
Say ("  内核流接口 (KSCATEGORY_VIDEO_CAMERA) 已注册: {0} 个" -f $ksCam.Count)
Say ""

if ($camAfter -and $ksCam.Count -ge 1) {
    Say ">>> 结果: 摄像头已就绪，应用可正常调用。" 'Green'
    Say "    请打开「相机」应用确认画面。"
    Say ""
    Say ">>> 重要: 快速启动已关闭 —— 请做一次【完全关机】再开机，"
    Say "    让 USB 控制器彻底复位，之后观察掉线是否复发。"
} else {
    Say ">>> 结果: 仍未就绪。" 'Yellow'
    Say "    -> 请先做「彻底断电复位」(README 步骤 1)，再试屏幕折角测试。"
}

Say ""
Say ("日志已写入: " + $logPath)
Save
