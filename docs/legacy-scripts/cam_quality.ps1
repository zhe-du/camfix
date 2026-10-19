# ============================================================
#  cam_quality.ps1 — 画质自测（判断是否被降级 / 客观清晰度）
#
#  用途: 觉得画面模糊时双击 cam-quality.cmd 跑一次
#  输出: 分辨率档位是否齐全、是否含 1080p、抓帧的客观清晰度
#  留档: quality-log.txt（历史）+ quality-frames\*.jpg（帧）
# ============================================================

[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Continue'
$dir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$log    = Join-Path $dir 'quality-log.txt'
$frames = Join-Path $dir 'quality-frames'
if (-not (Test-Path $frames)) { New-Item -ItemType Directory -Path $frames -Force | Out-Null }

function Find-Ffmpeg {
    $c = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @()
    foreach ($root in @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages", 'D:\LE\AI\tools', 'C:\ffmpeg')) {
        if (Test-Path $root) {
            $cands += @(Get-ChildItem $root -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue -Depth 6 | Select-Object -ExpandProperty FullName)
        }
    }
    if ($cands.Count -gt 0) { return $cands[0] }
    return $null
}

function Find-Python {
    foreach ($p in @(
        'C:\Users\zhedu\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe',
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")) {
        if (Test-Path $p) { return $p }
    }
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " 摄像头画质自测  $now" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

$verdict = '未知'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("[$now]")

# ---------- 1. 设备 ----------
$cam = pnputil /enum-devices /class Camera 2>&1
$present = [bool]($cam | Select-String -Pattern 'VID_174F')
$started = ($cam | Select-String -Pattern 'Status:\s+Started|状态:\s*已启动').Count -ge 1
Write-Host ("  设备: " + $(if (-not $present) { '不在总线上' } elseif ($started) { '在位且已启动' } else { '在位但未启动' }))
$lines.Add("  设备: present=$present started=$started")

$ff = Find-Ffmpeg
if (-not $ff) {
    Write-Host "  [!] 找不到 ffmpeg，无法检测画质" -ForegroundColor Yellow
    $lines.Add("  ffmpeg: 未找到")
    $lines | Add-Content -LiteralPath $log -Encoding UTF8
    if (-not $NoPause) { Read-Host "按回车退出" }
    exit 1
}
$lines.Add("  ffmpeg: $ff")

# ---------- 2. 分辨率档位（降级判据） ----------
$lo = & $ff -hide_banner -f dshow -list_options true -i video="Integrated Camera" 2>&1
$nfmt = @($lo | Select-String -Pattern 'pixel_format').Count
$has1080 = @($lo | Select-String -Pattern '1920x1080').Count -gt 0
$bindFail = [bool]($lo | Select-String -Pattern 'Unable to BindToObject|Could not find video device')

Write-Host ""
Write-Host "  --- 分辨率档位 ---"
if ($bindFail) {
    Write-Host "  [!] 无法绑定设备（可能正被其他应用占用）—— 这次结果不作数" -ForegroundColor Yellow
    $lines.Add("  档位: 绑定失败(设备忙)")
    $verdict = '设备忙'
} else {
    Write-Host ("  枚举到 {0} 档格式；含 1920x1080: {1}" -f $nfmt, $(if ($has1080) { '是' } else { '否' }))
    $lines.Add("  档位: $nfmt 档, 含1080p=$has1080")
    if ($nfmt -lt 5 -or -not $has1080) {
        Write-Host "  [X] 相机被降级！这就是画面变模糊的原因" -ForegroundColor Red
        $verdict = '降级(模糊)'
    } else {
        Write-Host "  [OK] 档位齐全，没有被降级" -ForegroundColor Green
        $verdict = '正常'
    }
}

# ---------- 3. 抓帧留档 ----------
Write-Host ""
Write-Host "  --- 抓帧 ---"
$jpg = Join-Path $frames ("frame_{0}.jpg" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$grabbed = $false
foreach ($size in @('1920x1080','1280x720')) {
    Remove-Item -LiteralPath $jpg -Force -ErrorAction SilentlyContinue
    & $ff -hide_banner -loglevel error -f dshow -video_size $size -i video="Integrated Camera" -frames:v 1 -y $jpg 2>&1 | Out-Null
    if ((Test-Path $jpg) -and (Get-Item $jpg).Length -gt 1000) {
        Write-Host ("  [OK] 抓到 {0} 帧: {1} 字节" -f $size, (Get-Item $jpg).Length) -ForegroundColor Green
        $lines.Add("  抓帧: $size, $((Get-Item $jpg).Length) 字节 -> $(Split-Path $jpg -Leaf)")
        $grabbed = $true
        break
    }
}
if (-not $grabbed) {
    Write-Host "  [X] 抓帧失败" -ForegroundColor Red
    $lines.Add("  抓帧: 失败")
}

# ---------- 4. 客观清晰度（有 Python 才算） ----------
$py = Find-Python
if ($grabbed -and $py) {
    $analyzer = Join-Path $dir 'analyze_cam_frame.py'
    if (Test-Path $analyzer) {
        Write-Host ""
        Write-Host "  --- 客观清晰度 ---"
        $r = & $py $analyzer $jpg 2>&1
        $r | ForEach-Object { Write-Host ("  " + $_) }
        $lines.Add(($r -join ' | '))
    }
} elseif ($grabbed) {
    Write-Host "  （没有 Python，跳过清晰度计算；帧已留档可自行查看）" -ForegroundColor DarkGray
}

$lines.Add("  判定: $verdict")
$lines.Add("")
$lines | Add-Content -LiteralPath $log -Encoding UTF8

Write-Host ""
Write-Host (" 判定: $verdict") -ForegroundColor $(if ($verdict -eq '正常') { 'Green' } else { 'Yellow' })
Write-Host (" 历史: $log")
Write-Host (" 帧目录: $frames")
Write-Host "=====================================================" -ForegroundColor Cyan
if (-not $NoPause) { Read-Host "按回车退出" }
