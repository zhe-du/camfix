# =====================================================================
#  cam_fix.ps1 - Repair USB enumeration for the built-in camera
#  Target machine : Lenovo ThinkBook 16 Gen 7 AHP (21MU), Windows 11
#  Diagnosed issue: Integrated Camera (USB\VID_174F&PID_1820) dropped off
#                   the USB bus; the same root-hub port now reports
#                   "Unknown USB Device (Device Descriptor Request Failed)".
#  Requires       : Administrator
#  Output         : cam_fix_log.txt (next to this script)
# =====================================================================

param([switch]$Deep)

$ErrorActionPreference = 'Continue'
$logPath = Join-Path $PSScriptRoot 'cam_fix_log.txt'
$script:logLines = New-Object System.Collections.ArrayList

function Say($msg, $color) {
    if ($color) { Write-Host $msg -ForegroundColor $color } else { Write-Host $msg }
    [void]$script:logLines.Add([string]$msg)
}
function Save() { Set-Content -Path $logPath -Value $script:logLines -Encoding UTF8 }

Say "====================================================="
Say " Camera / USB enumeration repair"
Say (" " + (Get-Date))
Say "====================================================="
Say ""

# ---------------------------------------------------------------- 0. admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say "[FAIL] This script must run as Administrator." 'Red'
    Save
    exit 1
}
Say "[OK] Running elevated."
Say ""

# ------------------------------------------------------- 1. snapshot before
Say "---------- BEFORE ----------"
$camBefore = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.Class -in @('Camera','Image') }
if ($camBefore) {
    foreach ($c in $camBefore) { Say ("  present: [" + $c.Status + "] " + $c.FriendlyName) }
} else {
    Say "  present: (no camera device attached)"
}

$bad = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.Status -ne 'OK' -and $_.InstanceId -like 'USB\*' }
if ($bad) {
    foreach ($b in $bad) { Say ("  faulty : [" + $b.Status + "] " + $b.FriendlyName + " | " + $b.InstanceId) }
} else {
    Say "  faulty : (none)"
}
Say ""

# --------------------------------------------------- 2. locate target nodes
$TARGET_VID = 'USB\VID_174F&PID_1820'

$failedNode = (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.Class -eq 'USB' -and $_.Status -eq 'Error' } |
               Select-Object -First 1)

$ghostCam = (Get-PnpDevice -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like ($TARGET_VID + '*') } |
             Select-Object -First 1)

$targetHub = $null
if ($ghostCam) {
    $targetHub = (Get-PnpDeviceProperty -InstanceId $ghostCam.InstanceId `
                  -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
}
if (-not $targetHub -and $failedNode) {
    $targetHub = (Get-PnpDeviceProperty -InstanceId $failedNode.InstanceId `
                  -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
}

Say "---------- TARGETS ----------"
Say ("  ghost camera : " + $(if ($ghostCam) { $ghostCam.InstanceId } else { '(not in enum db)' }))
Say ("  faulty node  : " + $(if ($failedNode) { $failedNode.InstanceId } else { '(none - good sign)' }))
Say ("  target hub   : " + $(if ($targetHub) { $targetHub } else { '(unknown)' }))
Say ""

# --------------------------------------------------------- 3. step: rescan
Say "[1/5] pnputil /scan-devices ..."
& pnputil.exe /scan-devices > $null 2>&1
Say ("      exit code = " + $LASTEXITCODE)
Start-Sleep -Seconds 2

# ------------------------------------------- 4. step: drop the failed node
if ($failedNode) {
    Say "[2/5] removing faulty node " + $failedNode.InstanceId
    & pnputil.exe /remove-device $failedNode.InstanceId > $null 2>&1
    Say ("      exit code = " + $LASTEXITCODE)
    Start-Sleep -Seconds 2
} else {
    Say "[2/5] no faulty USB node present - skipped."
}

# --------------------------------- 5. step: power-cycle the root hub port
if ($targetHub) {
    Say "[3/5] restarting USB root hub " + $targetHub
    Say "      (everything on this hub blinks off and re-enumerates - normal)"
    & pnputil.exe /restart-device $targetHub > $null 2>&1
    $rc = $LASTEXITCODE
    Say ("      pnputil /restart-device exit code = " + $rc)

    if ($rc -ne 0) {
        Say "      falling back to Disable-PnpDevice / Enable-PnpDevice ..."
        try {
            Disable-PnpDevice -InstanceId $targetHub -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 3
            Enable-PnpDevice  -InstanceId $targetHub -Confirm:$false -ErrorAction Stop
            Say "      [OK] hub cycled."
        } catch {
            Say ("      [FAIL] " + $_.Exception.Message) 'Red'
        }
    }
    Start-Sleep -Seconds 4
} else {
    Say "[3/5] target hub unknown - skipped."
}

# ------------------------------------------------------ 6. step: deep clean
if ($Deep) {
    Say "[4/5] DEEP: removing stale camera device nodes ..."
    $stale = Get-PnpDevice -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like ($TARGET_VID + '*') -or $_.FriendlyName -eq 'Lenovo Camera Group' }
    if ($stale) {
        foreach ($s in $stale) {
            Say ("      removing " + $s.InstanceId)
            & pnputil.exe /remove-device $s.InstanceId > $null 2>&1
        }
    } else {
        Say "      (nothing to remove)"
    }
    Start-Sleep -Seconds 2
} else {
    Say "[4/5] deep clean not requested (add  -Deep  to also purge stale camera nodes)."
}

# ------------------------------------------------------------- 7. rescan
Say "[5/5] pnputil /scan-devices ..."
& pnputil.exe /scan-devices > $null 2>&1
Start-Sleep -Seconds 5

# ------------------------------------------------------------- 8. result
Say ""
Say "---------- AFTER ----------"
$camAfter = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.Class -in @('Camera','Image') }
if ($camAfter) {
    foreach ($c in $camAfter) { Say ("  present: [" + $c.Status + "] " + $c.FriendlyName) }
    Say ""
    Say ">>> RESULT: CAMERA DETECTED. Open the Camera app to confirm." 'Green'
} else {
    $badAfter = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -ne 'OK' -and $_.InstanceId -like 'USB\*' }
    if ($badAfter) {
        foreach ($b in $badAfter) { Say ("  faulty : [" + $b.Status + "] " + $b.FriendlyName + " | " + $b.InstanceId) }
        Say ""
        Say ">>> RESULT: the port still reports a DESCRIPTOR FAILURE." 'Yellow'
        Say "    The camera is powered but not answering USB enumeration."
        Say "    -> Do the FULL POWER DRAIN (see README step 1), then check BIOS / cable."
    } else {
        Say "  present: (still nothing on the bus)"
        Say ""
        Say ">>> RESULT: no camera and no faulty node." 'Yellow'
        Say "    The camera is most likely cut off by BIOS or by the EC"
        Say "    (camera hotkey / privacy switch). See README steps 2 and 3."
    }
}

Say ""
Say ("Log written to: " + $logPath)
Save
