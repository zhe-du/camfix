# CamFix — Windows 内置摄像头「间歇性失效 / 画面降级」诊断工具

一个针对 **ThinkBook 16 G7 AHP (21MU)** 内置摄像头间歇性失效问题的根因分析与诊断工具。
**C++17 + Win32 API,单文件 exe,零依赖。**

> **结论先行**:这是 Windows 现代待机(Modern Standby)的电源管理行为,与 Realtek DMFT
> 复合相机「选择性暂停」能力不匹配所致 —— **不是摄像头硬件损坏**。

---

## 现象

同一台机器上出现两种看似无关的症状:

| 症状 | 表现 |
|---|---|
| A | 相机从设备管理器消失,相机应用报 `0xA00F4244 NoCamerasAreAttached` |
| B | 相机**仍在位**、状态显示「已启动」,但只能输出 **160×120 @9fps**,画面糊到不可用 |
| C | 两者都会在一段时间后**自行恢复**(无需重启) |

**关键点**:症状 B 里设备状态是正常的 —— 所以"重装驱动/换硬件"这些思路都解释不了它。

---

## 根因

本机为 **S0 低电量待机(Modern Standby)**。Windows 的规则是:

> 只有挂在同一 USB 控制器上的**所有设备都进入低功耗**,控制器才允许断电进入 **DRIPS**。

该相机是**复合设备**(`MI_00` RGB / `MI_02` IR / `MI_04` DFU),带联想 DMFT 机制
(`USB\MS_COMP_LNVDMFT` + `WdmCompanionFilter` + `lnvdmft.inf`)。只要有一个接口无法
正确进入/退出 D3,整条控制器就被拖住 → 相机被判为 **DRIPS 阻止设备** → 系统**强制移除**它。

系统日志直接记录了这一幕(来源 `Microsoft-Windows-USB-USBHUB3`):

```
事件 ID 196
  在系统处于空闲状态时耗尽系统电源的 USB 设备。
  USB 设备: VID: 0x174F PID: 0x1820 REV: 0x1112
  删除操作失败: QueryRemovalInitiated

事件 ID 205
  重新枚举以前在电池电量不足时删除的 DRIPS 阻止设备。
```

微软对此有专门定义:bug check **`0x1A5 USB_DRIPS_BLOCKER_SURPRISE_REMOVAL_LIVEDUMP`** ——
*"阻止顶层控制器在现代待机期间断电的 USB 设备,将被强制移除(surprise removed)。"*

**于是三种症状对应同一原因:**
- 移除成功 → 相机消失(症状 A)
- 移除失败但枚举状态受损 → 重枚举只协商出 160×120(症状 B)
- 重新枚举成功 → 自行恢复(症状 C)

---

## 这个工具做什么

```
CamFix.exe              诊断;仅在需要时提权恢复(正常时免 UAC、不打扰)
CamFix.exe --diag       只诊断,免管理员
CamFix.exe --status     单行状态输出(供脚本调用)
CamFix.exe --recover    只重启相机设备(恢复画质)
CamFix.exe --repair     完整修复: 注册表备份 + 设备级参数 + 全局 hub 开关 + 电源计划 + 重启
CamFix.exe --restore    回滚到最近一次 backup\*.reg
CamFix.exe --auto       静默自检(供开机自启),异常才弹窗
```

诊断项(**全部语言无关**,不解析任何本地化文本):

1. 相机是否在场 / 是否已启动(`SetupDiGetClassDevsW` + `CM_Get_DevNode_Status`)
2. **格式档位**:DirectShow `IAMStreamConfig` 枚举输出引脚 → 正常 21 档含 1080p,降级仅 1 档 160×120
3. USB 选择性暂停是否被复位成「启用」(PowrProf API)
4. 全局 hub 开关 `USBHUB3` / `usbhub` 的 `DisableSelectiveSuspend`
5. **DRIPS 事件统计**:读 System 日志里 ID 196/205 近 24h 的次数(`EvtQuery`)

---

## 构建

依赖 [MinGW-w64](https://github.com/niXman/mingw-builds-binaries) g++ 16.2.0。

```bat
:: 编译（cmd）
build.cmd

:: 编译 + 自检 + 部署
build.cmd release

:: 或使用 Makefile（增量编译）
mingw32-make
```

构建脚本 `build.cmd` 支持:`build` / `release` / `icon` / `all` / `test` / `clean` / `help`。

> 注意:含中文的 `.cmd` 必须保存为 **GBK(936)**,否则 cmd 会把乱码字节误当语法符号。

---

## 技术要点(踩坑记录)

| 坑 | 解决 |
|---|---|
| 用 `pnputil` 文本判断设备状态 → 输出语言随环境变(英文 `Status: Started` / 中文 `状态: 已启动`) | 改用 `SetupDiGetClassDevsW` + `CM_Get_DevNode_Status` 直读 |
| `WriteConsoleW` 在输出重定向时**静默失败** | 按句柄类型分流,重定向走 `WriteFile` + UTF-8 |
| `IAMStreamConfig` 挂在**输出引脚**上,不在滤波器本体 | 先 `EnumPins` 找 `PINDIR_OUTPUT` 再 `QueryInterface` |
| `Pause()` 在非交互环境永久挂起并锁住 exe | `GetConsoleMode(stdin)` 判定,非控制台直接返回 |
| 只设 `cell.width` 的表格会被内容撑宽 | OOXML 里要同时写 `tblW` + `tblLayout=fixed` + `tblGrid/gridCol` |

---

## 免责声明

- 本项目仅用于**诊断与临时规避**,不修改系统关键配置;
- 「重启设备」类操作需要管理员权限;
- 本项目与 Lenovo / Realtek 无关,不代表厂商立场;
- 若你的机器也有类似现象,建议先保留系统事件日志(`Microsoft-Windows-USB-USBHUB3`)再操作。

---

## 许可

MIT
