# 早期 PowerShell 脚本链（已归档）

这些脚本是 `CamFix.exe` 出现**之前**用的版本，保留是为了记录排查过程，不是推荐用法。

**新用户请直接用 [`CamFix.exe`](../../README.md)，不要用这里的脚本。**

---

## 为什么被替换

早期方案是「4 个 .cmd 包裹 + 5 个 .ps1 + 1 个 Python 分析器」，有三个硬伤：

| 问题 | 后果 |
|---|---|
| 靠解析 `pnputil` 的**本地化文本**判断设备状态 | 输出语言随环境变（英文 `Status: Started` / 中文 `状态: 已启动`），曾导致**误报"相机在位但未启动"** |
| 脚本自身不能声明「需要管理员」 | 必须用 `.cmd` 再包一层，链路变长 |
| 含中文的 `.ps1` 必须存成 UTF-8 + BOM | 存错就乱码，且报错信息很不直观 |

`CamFix.exe` 改用 `SetupDiGetClassDevsW` + `CM_Get_DevNode_Status` 直读设备状态，
不再依赖任何本地化字符串，单文件、需要时才自我提权。

---

## 文件清单

| 文件 | 作用 | 配套 .cmd |
|---|---|---|
| `cam_check.ps1` | 免管理员状态自检：设备态 / 到达时间 / 内核流接口 / 隐私 / 快速启动 | `cam-check.cmd` |
| `cam_rootfix.ps1` | 关快速启动 + 关 USB 选择性暂停 + 清幽灵节点 + 重启根集线器；支持 `-Deep` / `-Restore` | `cam-rootfix.cmd` |
| `cam_deep_repair.ps1` | 深度阶梯：清节点 → 重扫 → 根集线器 → 循环 xHCI | （`CamFix.exe --deep` 已取代） |
| `cam_recover.ps1` | 只重启相机复合设备 | `cam-recover.cmd` |
| `cam_quality.ps1` | 用 DirectShow 枚举格式档位，判断是否降级到 160×120 | `cam-quality.cmd` |
| `verify_fix.ps1` | 修复后的复验 | `verify-fix.cmd` |
| `repair_camera.ps1` | 完整修复：注册表备份 + 设备级参数 + hub 开关 + 电源计划 | `repair-camera.cmd` |
| `cam_watch.ps1` | 常驻监听，相机掉线时抓现场 | `watch-camera.cmd` |
| `auto_verify.ps1` | 开机静默自检（发现问题才弹窗） | `cam-auto-verify.cmd` |
| `cam_fix.ps1` | 最早的急救版：只重扫 + 拔插根集线器，不改系统设置 | `fix-camera.cmd` |

---

## 使用前必须改的地方

**根集线器实例 ID 是本机专属的**，换机器要改：

```powershell
USB\ROOT_HUB30\5&8b8e61a&0&0
```

出现在：

- `cam_rootfix.ps1`（兜底值）
- `cam_recover.ps1`
- `cam_deep_repair.ps1`
- `cam_watch.ps1`

正确做法是先查自己机器上的值：

```powershell
Get-PnpDevice -Class USB | Where-Object { $_.InstanceId -like 'USB\ROOT_HUB30*' } |
    Select-Object -ExpandProperty InstanceId
```

（`repair_camera.ps1` 里已经改成动态查找，可作参考。）

另外，相机硬件 ID `USB\VID_174F&PID_1820` 是这台机器的 Realtek DMFT 复合相机，
换机型需要改 `cam_*.ps1` 里的匹配条件。

---

## 执行策略

含中文的 `.ps1` 是 UTF-8 + BOM。如果直接 `& script.ps1` 报"无法加载"或静默不执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

或者用 `.cmd` 启动器（里面已经带 `-ExecutionPolicy Bypass`）。

---

## 许可

与主项目一致，MIT。
