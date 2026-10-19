# =====================================================================
#  cam_check.ps1  -  Quick camera status check (NO admin required)
#  Target : Lenovo ThinkBook 16 Gen 7 AHP (21MU), Windows 11
#  Prints : device state, USB port path, driver, privacy, kernel-stream
#           interfaces, and a plain verdict.
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'

function Line($t, $c) { if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t } }

Line "================ 摄像头状态检查 ================"
Line ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Line ""

$cam = Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in @('Camera','Image') }
if ($cam) {
    foreach ($c in $cam) {
        $p = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo').Data
        Line ("[设备] {0}  ->  {1}" -f $c.Status, $c.FriendlyName)
        Line ("       实例: {0}" -f $c.InstanceId)
        Line ("       位置: {0}" -f $p)
    }
} else {
    Line "[设备] 相机当前不在总线上" 'Yellow'
}

Line ""
$arr = Get-PnpDevice | Where-Object { $_.InstanceId -like 'USB\VID_174F&PID_1820*' } | Select-Object -First 1
if ($arr) {
    $ad = (Get-PnpDeviceProperty -InstanceId $arr.InstanceId -KeyName 'DEVPKEY_Device_LastArrivalDate').Data
    Line ("[到达] 相机最近一次上线: {0}" -f $ad)
}
$bad = Get-PnpDevice | Where-Object { $_.InstanceId -like 'USB\VID_0000&PID_0002*' }
if ($bad) {
    foreach ($b in $bad) {
        Line (("[异常] {0}  ({1})" -f $b.FriendlyName, $b.Status)) 'Yellow'
    }
} else {
    Line "[异常] 无「设备描述符请求失败」节点"
}

Line ""
$ksKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-f976-4f5b-9b55-b94699c46e44}'
$ks = @(Get-ChildItem $ksKey | Where-Object { $_.PSChildName -like '*VID_174F*' })
Line ("[接口] 内核流接口(KSCATEGORY_VIDEO_CAMERA)已注册: {0} 个" -f $ks.Count)

$p1 = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam').Value
$p2 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam').Value
Line ("[隐私] 用户级={0} / 机器级={1}" -f $p1, $p2)

$hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled).HiberbootEnabled
Line ("[设置] 快速启动 HiberbootEnabled={0}  (1=开启, 0=关闭)" -f $hb)

Line ""
$okCam = @($cam | Where-Object { $_.Status -eq 'OK' })
if ($okCam.Count -ge 1 -and $ks.Count -ge 1) {
    Line ">>> 判决: 摄像头【正常可用】。打开「相机」应用即可。" 'Green'
} elseif ($okCam.Count -ge 1) {
    Line ">>> 判决: 设备已枚举，但内核流接口未注册 —— 建议重启一次。" 'Yellow'
} else {
    Line ">>> 判决: 摄像头【不在总线上】。请运行 cam-rootfix.cmd 做修复。" 'Yellow'
}
Line "================================================"
