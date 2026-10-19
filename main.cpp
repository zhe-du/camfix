// ============================================================
//  CamFix.exe — 内置摄像头 诊断 / 恢复 / 修复
//  机型: ThinkBook 16 G7 AHP (21MU) / Realtek DMFT 双摄 (VID_174F&PID_1820)
//
//  为什么要用 C++ 重写(替换 PowerShell 版):
//    1) 脚本靠解析 pnputil 的**本地化文本**判断状态 —— 输出语言随运行环境
//       变化(DSH 里英文 Status: Started、用户会话里中文 状态: 已启动),
//       这是之前假警报的直接原因。本程序改用 SetupAPI/CfgMgr32 直接取状态。
//    2) 脚本要 .cmd 包裹才能提权, 且中文脚本必须 UTF-8+BOM, 易乱码。
//       本程序单文件 exe, 需要时用 ShellExecuteExW("runas") 自我提权。
//    3) 脚本依赖 pnputil.exe 存在与参数语义; 本程序直接调 DIF_PROPERTYCHANGE。
//
//  故障背景(2026-10-11 锁定):
//    系统为 S0 低电量待机(Modern Standby), 空闲时为了进入 DRIPS 深度省电,
//    会尝试删除「阻止 DRIPS 的设备」——相机属于该类(USBHUB3 事件 ID 196 点名
//    VID_0x174F PID_0x1820, 删除操作失败: QueryRemovalInitiated)。
//    删除成功 -> 相机消失(0xA00F4244); 删除失败但状态受损 -> 重枚举后只剩
//    160x120 一档 -> 画面模糊; 重枚举正常 -> 21 档含 1080p。
//
//  用法:
//    CamFix.exe              默认: 诊断 -> 自动恢复/修复 -> 报告
//    CamFix.exe --diag       只诊断(免管理员)
//    CamFix.exe --recover    只重启相机设备(恢复画质)
//    CamFix.exe --repair     完整修复: 设备级参数 + 全局 hub 开关 + 电源计划 + 重启
//    CamFix.exe --restore    回滚注册表参数到上一次备份
//    CamFix.exe --no-pause   结束时不等待按键
//
//  编译: 见同目录 build.cmd (MinGW-w64 g++ 16.2.0)
// ============================================================

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00

#include <windows.h>
#include <shellapi.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <initguid.h>
#include <dshow.h>
#include <winevt.h>
#include <cstdlib>
#include <string>
#include <vector>
#include <cstdarg>
#include <cstdio>

// 相机设备安装类 {ca3e7ab9-b4c3-4ae6-8251-579ef933890f}
DEFINE_GUID(GUID_DEVCLASS_CAMERA_LOCAL,
            0xca3e7ab9, 0xb4c3, 0x4ae6, 0x82, 0x51, 0x57, 0x9e, 0xf9, 0x33, 0x89, 0x0f);

// USB 设置子组 {2a737441-1930-4402-8d77-b2bebba308a3} 下的「USB 选择性暂停设置」
DEFINE_GUID(GUID_USB_SUBGROUP, 0x2a737441, 0x1930, 0x4402, 0x8d, 0x77, 0xb2, 0xbe, 0xbb, 0xa3, 0x08, 0xa3);
DEFINE_GUID(GUID_USB_SEL_SUSPEND, 0x48e6b7a6, 0x50f5, 0x4782, 0xa5, 0xd4, 0x53, 0xbb, 0x8f, 0x07, 0xe2, 0x26);

// ---------------- 常量 ----------------
static const wchar_t* kCamIdPart   = L"VID_174F&PID_1820";
static const wchar_t* kCamIdParent = L"USB\\VID_174F&PID_1820";
static const wchar_t* kCamFriendly = L"Integrated Camera";
static const wchar_t* kSvcUsbHub3  = L"SYSTEM\\CurrentControlSet\\Services\\USBHUB3";
static const wchar_t* kSvcUsbHub   = L"SYSTEM\\CurrentControlSet\\Services\\usbhub";
static const wchar_t* kEnumUsb     = L"SYSTEM\\CurrentControlSet\\Enum\\USB";
static const wchar_t* kRootHubHint = L"USB\\ROOT_HUB30";

// ---------------- 输出(宽字符, 避开 %s 窄串坑) ----------------
static HANDLE g_out = INVALID_HANDLE_VALUE;
static HANDLE g_log = INVALID_HANDLE_VALUE;

static void SetColor(WORD c) {
    if (g_out != INVALID_HANDLE_VALUE) SetConsoleTextAttribute(g_out, c);
}
static void WriteUtf8(HANDLE h, const wchar_t* s) {
    if (h == INVALID_HANDLE_VALUE || !s) return;
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return;
    std::string buf((size_t)n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s, -1, &buf[0], n, nullptr, nullptr);
    DWORD wr = 0;
    WriteFile(h, buf.data(), (DWORD)buf.size(), &wr, nullptr);
}
static void OutRaw(const wchar_t* s) {
    if (!s) return;
    if (g_log != INVALID_HANDLE_VALUE) WriteUtf8(g_log, s);   // 一律留档
    if (g_out == INVALID_HANDLE_VALUE) return;
    DWORD mode = 0;
    if (GetConsoleMode(g_out, &mode)) {
        DWORD w = 0;
        WriteConsoleW(g_out, s, (DWORD)wcslen(s), &w, nullptr);
    } else {
        WriteUtf8(g_out, s);   // 重定向时 WriteConsoleW 会静默失败
    }
}

static void Line(const wchar_t* fmt, ...) {
    wchar_t buf[4096];
    va_list ap; va_start(ap, fmt);
    _vsnwprintf(buf, 4094, fmt, ap);
    va_end(ap);
    buf[4094] = 0;
    OutRaw(buf);
    OutRaw(L"\n");
}
enum Col { C_DEF = 7, C_OK = 10, C_WARN = 14, C_ERR = 12, C_HEAD = 11, C_DIM = 8 };

static void Ok(const wchar_t* s)   { SetColor(C_OK);   Line(L"  [OK] %ls", s); SetColor(C_DEF); }
static void Warn(const wchar_t* s) { SetColor(C_WARN); Line(L"  [!]  %ls", s); SetColor(C_DEF); }
static void Err(const wchar_t* s)  { SetColor(C_ERR);  Line(L"  [X]  %ls", s); SetColor(C_DEF); }
static void Info(const wchar_t* s) { SetColor(C_DIM);  Line(L"  %ls", s);     SetColor(C_DEF); }

// ---------------- 提权 ----------------
static bool IsElevated() {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return false;
    TOKEN_ELEVATION el{}; DWORD sz = sizeof(el);
    bool r = GetTokenInformation(tok, TokenElevation, &el, sz, &sz) && el.TokenIsElevated;
    CloseHandle(tok);
    return r;
}
static bool RelaunchElevated() {
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    // 原样带上命令行参数
    const wchar_t* full = GetCommandLineW();
    std::wstring params;
    if (full) {
        // 跳过 argv[0]（可能有引号）
        const wchar_t* p = full;
        if (*p == L'"') { ++p; while (*p && *p != L'"') ++p; if (*p == L'"') ++p; }
        else { while (*p && *p != L' ') ++p; }
        while (*p == L' ') ++p;
        params = p;
    }
    SHELLEXECUTEINFOW sei{};
    sei.cbSize = sizeof(sei);
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = exe;
    sei.lpParameters = params.empty() ? nullptr : params.c_str();
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei)) {
        Line(L"  [X] 提权失败(你在 UAC 里点了「否」?) 错误码 %lu", GetLastError());
        return false;
    }
    if (sei.hProcess) CloseHandle(sei.hProcess);
    return true;
}

// ---------------- 设备枚举 ----------------
struct DevItem {
    std::wstring instanceId;
    std::wstring desc;
    DEVINST      devInst = 0;
    bool         started = false;
    ULONG        problem = 0;
};

static std::vector<DevItem> EnumCameras() {
    std::vector<DevItem> out;
    HDEVINFO h = SetupDiGetClassDevsW(&GUID_DEVCLASS_CAMERA_LOCAL, nullptr, nullptr, DIGCF_PRESENT);
    if (h == INVALID_HANDLE_VALUE) return out;
    SP_DEVINFO_DATA d{}; d.cbSize = sizeof(d);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(h, i, &d); ++i) {
        wchar_t id[512]{}; if (!SetupDiGetDeviceInstanceIdW(h, &d, id, 512, nullptr)) continue;
        if (wcsstr(id, kCamIdPart) == nullptr) continue;
        DevItem it; it.instanceId = id; it.devInst = d.DevInst;
        wchar_t desc[512]{};
        if (SetupDiGetDeviceRegistryPropertyW(h, &d, SPDRP_DEVICEDESC, nullptr, (PBYTE)desc, sizeof(desc), nullptr))
            it.desc = desc;
        ULONG status = 0;
        if (CM_Get_DevNode_Status(&status, &it.problem, d.DevInst, 0) == CR_SUCCESS)
            it.started = (status & DN_STARTED) != 0;
        out.push_back(it);
    }
    SetupDiDestroyDeviceInfoList(h);
    return out;
}

// 找某个 instanceId 前缀的第一个设备(用于定位复合设备)
static bool FindInstance(const std::wstring& prefix, std::wstring& found) {
    HDEVINFO h = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (h == INVALID_HANDLE_VALUE) return false;
    SP_DEVINFO_DATA d{}; d.cbSize = sizeof(d);
    bool ok = false;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(h, i, &d); ++i) {
        wchar_t id[512]{};
        if (!SetupDiGetDeviceInstanceIdW(h, &d, id, 512, nullptr)) continue;
        if (_wcsnicmp(id, prefix.c_str(), prefix.size()) == 0) { found = id; ok = true; break; }
    }
    SetupDiDestroyDeviceInfoList(h);
    return ok;
}

// 重启设备 = 设备管理器里那个「重启设备」(pnputil /restart-device 的等价物)
static bool RestartDevice(const std::wstring& instanceId) {
    HDEVINFO h = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES);
    if (h == INVALID_HANDLE_VALUE) return false;
    SP_DEVINFO_DATA d{}; d.cbSize = sizeof(d);
    bool ok = false;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(h, i, &d); ++i) {
        wchar_t id[512]{};
        if (!SetupDiGetDeviceInstanceIdW(h, &d, id, 512, nullptr)) continue;
        if (_wcsicmp(id, instanceId.c_str()) != 0) continue;
        SP_PROPCHANGE_PARAMS p{};
        p.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        p.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
        p.StateChange = DICS_PROPCHANGE;
        p.Scope = DICS_FLAG_GLOBAL;
        p.HwProfile = 0;
        if (SetupDiSetClassInstallParamsW(h, &d, &p.ClassInstallHeader, sizeof(p)))
            ok = (SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, h, &d) != FALSE);
        break;
    }
    SetupDiDestroyDeviceInfoList(h);
    return ok;
}

// ---------------- 格式档位(判断"模糊"降级) ----------------
// 从 filter 上取指定方向的第一个引脚（IAMStreamConfig 挂在输出引脚上）
static IPin* GetFirstPin(IBaseFilter* f, PIN_DIRECTION dir) {
    IEnumPins* pe = nullptr;
    if (!f || FAILED(f->EnumPins(&pe)) || !pe) return nullptr;
    IPin* p = nullptr; ULONG got = 0; IPin* found = nullptr;
    while (pe->Next(1, &p, &got) == S_OK) {
        PIN_DIRECTION d{};
        if (SUCCEEDED(p->QueryDirection(&d)) && d == dir) { found = p; break; }
        p->Release(); p = nullptr;
    }
    pe->Release();
    return found;
}
struct FmtInfo { int count = -1; bool has1080 = false; bool bindFail = false; std::wstring note; long hrCo = 0; long hrInit = 0; };

static FmtInfo QueryFormats() {
    FmtInfo r;
    // COM 可能已被本线程初始化过, 用 RPC_E_CHANGED_MODE 容忍
    HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ICreateDevEnum* pEnum = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_SystemDeviceEnum, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_ICreateDevEnum, (void**)&pEnum);
    if (FAILED(hr)) { r.note = L"CoCreateInstance 失败"; r.hrCo = (long)hr; r.hrInit = (long)hrInit; return r; }

    IEnumMoniker* pMon = nullptr;
    hr = pEnum->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, &pMon, 0);
    if (hr != S_OK) { pEnum->Release(); r.note = L"没有视频输入设备"; r.count = 0; return r; }

    IMoniker* pMk = nullptr; int matched = 0;
    while (pMon->Next(1, &pMk, nullptr) == S_OK) {
        // 读 FriendlyName
        IPropertyBag* pBag = nullptr;
        std::wstring name;
        if (SUCCEEDED(pMk->BindToStorage(nullptr, nullptr, IID_IPropertyBag, (void**)&pBag))) {
            VARIANT v; VariantInit(&v);
            if (SUCCEEDED(pBag->Read(L"FriendlyName", &v, nullptr)) && v.vt == VT_BSTR)
                name = v.bstrVal;
            VariantClear(&v);
            pBag->Release();
        }
        if (!name.empty() && wcsstr(name.c_str(), kCamFriendly)) {
            matched++;
            IBaseFilter* pFilter = nullptr;
            if (SUCCEEDED(pMk->BindToObject(nullptr, nullptr, IID_IBaseFilter, (void**)&pFilter))) {
                IAMStreamConfig* pCfg = nullptr;
                IPin* pOut = GetFirstPin(pFilter, PINDIR_OUTPUT);
                if (pOut) pOut->QueryInterface(IID_IAMStreamConfig, (void**)&pCfg);
                if (pCfg) {
                    int n = 0, sz = 0;
                    if (SUCCEEDED(pCfg->GetNumberOfCapabilities(&n, &sz))) {
                        r.count = n;
                        std::vector<BYTE> buf(sz);
                        for (int k = 0; k < n; ++k) {
                            AM_MEDIA_TYPE* pmt = nullptr;
                            if (SUCCEEDED(pCfg->GetStreamCaps(k, &pmt, buf.data()))) {
                                if (pmt->formattype == FORMAT_VideoInfo && pmt->pbFormat) {
                                    VIDEOINFOHEADER* vih = (VIDEOINFOHEADER*)pmt->pbFormat;
                                    if (vih->bmiHeader.biWidth >= 1920 && vih->bmiHeader.biHeight >= 1080)
                                        r.has1080 = true;
                                }
                                if (pmt->pUnk) pmt->pUnk->Release();
                                CoTaskMemFree(pmt->pbFormat);
                                CoTaskMemFree(pmt);
                            }
                        }
                    }
                    pCfg->Release();
                }
                if (pOut) pOut->Release();
                pFilter->Release();
            }
        }
        pMk->Release();
        if (matched > 0) break;
    }
    pMon->Release();
    pEnum->Release();
    if (matched == 0) { r.count = 0; r.note = L"DirectShow 里找不到 Integrated Camera"; r.bindFail = true; }
    if (hrInit == S_OK || hrInit == S_FALSE) CoUninitialize();
    return r;
}

// ---------------- 注册表 ----------------
static bool RegSetDword(HKEY root, const std::wstring& sub, const std::wstring& name, DWORD val) {
    HKEY k = nullptr;
    if (RegCreateKeyExW(root, sub.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &k, nullptr) != ERROR_SUCCESS)
        return false;
    LSTATUS st = RegSetValueExW(k, name.c_str(), 0, REG_DWORD, (const BYTE*)&val, sizeof(val));
    RegCloseKey(k);
    return st == ERROR_SUCCESS;
}
static bool RegGetDword(HKEY root, const std::wstring& sub, const std::wstring& name, DWORD& val, bool& present) {
    HKEY k = nullptr;
    present = false; val = 0;
    if (RegOpenKeyExW(root, sub.c_str(), 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS) return false;
    DWORD type = 0, sz = sizeof(DWORD);
    LSTATUS st = RegQueryValueExW(k, name.c_str(), nullptr, &type, (BYTE*)&val, &sz);
    RegCloseKey(k);
    if (st == ERROR_SUCCESS && type == REG_DWORD) { present = true; return true; }
    return false;
}

// 枚举 USB\VID_174F&PID_1820* 及其子键, 返回 key 路径列表(相对 HKLM)
static std::vector<std::wstring> EnumCamRegKeys() {
    std::vector<std::wstring> keys;
    HKEY hUsb = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kEnumUsb, 0, KEY_READ, &hUsb) != ERROR_SUCCESS) return keys;
    wchar_t sub[512]{};
    for (DWORD i = 0; RegEnumKeyW(hUsb, i, sub, 512) == ERROR_SUCCESS; ++i) {
        if (wcsstr(sub, kCamIdPart) == nullptr) continue;
        std::wstring base = std::wstring(kEnumUsb) + L"\\" + sub;
        // 自身也算(复合设备)
        keys.push_back(base);
        HKEY hSub = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, base.c_str(), 0, KEY_READ, &hSub) == ERROR_SUCCESS) {
            wchar_t inst[512]{};
            for (DWORD j = 0; RegEnumKeyW(hSub, j, inst, 512) == ERROR_SUCCESS; ++j)
                keys.push_back(base + L"\\" + inst);
            RegCloseKey(hSub);
        }
    }
    RegCloseKey(hUsb);
    return keys;
}

static bool BackupRegistry(const std::wstring& outFile) {
    // 用 reg.exe export 简单可靠(不改系统状态)
    std::wstring cmd = L"reg.exe export \"HKLM\\" + std::wstring(kEnumUsb) +
                       L"\" \"" + outFile + L"\" /y";
    STARTUPINFOW si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmd.begin(), cmd.end()); buf.push_back(0);
    if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, nullptr, &si, &pi)) return false;
    WaitForSingleObject(pi.hProcess, 30000);
    DWORD code = 1; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return code == 0;
}

// ---------------- 电源计划(USB 选择性暂停) ----------------
typedef DWORD (WINAPI *PFN_PowerGetActiveScheme)(HKEY, GUID**);
typedef DWORD (WINAPI *PFN_PowerWriteACValueIndex)(HKEY, const GUID*, const GUID*, const GUID*, DWORD);
typedef DWORD (WINAPI *PFN_PowerWriteDCValueIndex)(HKEY, const GUID*, const GUID*, const GUID*, DWORD);
typedef DWORD (WINAPI *PFN_PowerSetActiveScheme)(HKEY, const GUID*);
typedef DWORD (WINAPI *PFN_PowerReadACValueIndex)(HKEY, const GUID*, const GUID*, const GUID*, DWORD*);

struct PowrLib {
    HMODULE h = nullptr;
    PFN_PowerGetActiveScheme   GetActive = nullptr;
    PFN_PowerWriteACValueIndex WriteAC = nullptr;
    PFN_PowerWriteDCValueIndex WriteDC = nullptr;
    PFN_PowerSetActiveScheme   SetActive = nullptr;
    PFN_PowerReadACValueIndex  ReadAC = nullptr;
    bool Load() {
        h = LoadLibraryW(L"powrprof.dll");   // 坑: 不能靠 GetModuleHandle
        if (!h) return false;
        GetActive = (PFN_PowerGetActiveScheme)GetProcAddress(h, "PowerGetActiveScheme");
        WriteAC   = (PFN_PowerWriteACValueIndex)GetProcAddress(h, "PowerWriteACValueIndex");
        WriteDC   = (PFN_PowerWriteDCValueIndex)GetProcAddress(h, "PowerWriteDCValueIndex");
        SetActive = (PFN_PowerSetActiveScheme)GetProcAddress(h, "PowerSetActiveScheme");
        ReadAC    = (PFN_PowerReadACValueIndex)GetProcAddress(h, "PowerReadACValueIndex");
        return GetActive && WriteAC && WriteDC && SetActive;
    }
};

static bool ReadUsbSelSuspend(DWORD& ac) {
    PowrLib p; if (!p.Load() || !p.ReadAC) return false;
    GUID* g = nullptr;
    if (p.GetActive(nullptr, &g) != ERROR_SUCCESS || !g) return false;
    DWORD v = 0;
    DWORD st = p.ReadAC(nullptr, g, &GUID_USB_SUBGROUP, &GUID_USB_SEL_SUSPEND, &v);
    LocalFree(g);
    if (st != ERROR_SUCCESS) return false;
    ac = v; return true;
}
static bool DisableUsbSelSuspend() {
    PowrLib p; if (!p.Load()) return false;
    GUID* g = nullptr;
    if (p.GetActive(nullptr, &g) != ERROR_SUCCESS || !g) return false;
    bool ok = p.WriteAC(nullptr, g, &GUID_USB_SUBGROUP, &GUID_USB_SEL_SUSPEND, 0) == ERROR_SUCCESS;
    ok = (p.WriteDC(nullptr, g, &GUID_USB_SUBGROUP, &GUID_USB_SEL_SUSPEND, 0) == ERROR_SUCCESS) && ok;
    p.SetActive(nullptr, g);
    LocalFree(g);
    return ok;
}

// ---------------- 全局 hub 开关 ----------------
static int FixGlobalHubSwitch() {
    int n = 0;
    if (RegSetDword(HKEY_LOCAL_MACHINE, kSvcUsbHub3, L"DisableSelectiveSuspend", 1)) n++;
    if (RegSetDword(HKEY_LOCAL_MACHINE, kSvcUsbHub,  L"DisableSelectiveSuspend", 1)) n++;
    return n;
}

// 设备级 4 项参数
static int FixDeviceParams(const std::vector<std::wstring>& keys) {
    int n = 0;
    for (const auto& k : keys) {
        std::wstring dp = k + L"\\Device Parameters";
        // 只对真实存在 Device Parameters 的实例写(避免给无关键造垃圾)
        HKEY t = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, dp.c_str(), 0, KEY_READ, &t) != ERROR_SUCCESS) continue;
        RegCloseKey(t);
        if (RegSetDword(HKEY_LOCAL_MACHINE, dp, L"SelectiveSuspendEnabled", 0)) n++;
        if (RegSetDword(HKEY_LOCAL_MACHINE, dp, L"AllowIdleIrpInD3", 0)) n++;
        if (RegSetDword(HKEY_LOCAL_MACHINE, dp, L"EnhancedPowerManagementEnabled", 0)) n++;
        if (RegSetDword(HKEY_LOCAL_MACHINE, dp, L"EnumerationRetryCount", 3)) n++;
    }
    return n;
}

// ---------------- 深度修复用的底层能力 ----------------
// 隐藏执行外部命令（只用于 pnputil 的「动作」，绝不用来解析任何本地化文本）
static bool RunHidden(const std::wstring& cmd, DWORD timeoutMs = 30000) {
    STARTUPINFOW si{}; si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmd.begin(), cmd.end()); buf.push_back(0);
    if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, nullptr, &si, &pi)) return false;
    WaitForSingleObject(pi.hProcess, timeoutMs);
    DWORD code = 1; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return code == 0;
}

// 从 Enum\USB\<hwid>\<inst> 收集完整设备实例 ID（含「幽灵」设备）
// 幽灵设备在 SetupAPI 的 present 枚举里拿不到，只能从注册表挖。
static std::vector<std::wstring> EnumInstanceIds(const wchar_t* hwidPart) {
    std::vector<std::wstring> out;
    HKEY hUsb = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kEnumUsb, 0, KEY_READ, &hUsb) != ERROR_SUCCESS) return out;
    wchar_t sub[512]{};
    for (DWORD i = 0; RegEnumKeyW(hUsb, i, sub, 512) == ERROR_SUCCESS; ++i) {
        if (wcsstr(sub, hwidPart) == nullptr) continue;
        std::wstring base = std::wstring(kEnumUsb) + L"\\" + sub;
        HKEY hSub = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, base.c_str(), 0, KEY_READ, &hSub) != ERROR_SUCCESS) continue;
        wchar_t inst[512]{};
        for (DWORD j = 0; RegEnumKeyW(hSub, j, inst, 512) == ERROR_SUCCESS; ++j)
            out.push_back(std::wstring(L"USB\\") + sub + L"\\" + inst);
        RegCloseKey(hSub);
    }
    RegCloseKey(hUsb);
    return out;
}

// 启用/禁用设备 = 设备管理器右键「禁用设备」/「启用设备」
static bool SetDeviceEnabled(const std::wstring& instanceId, bool enable) {
    HDEVINFO h = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES);
    if (h == INVALID_HANDLE_VALUE) return false;
    SP_DEVINFO_DATA d{}; d.cbSize = sizeof(d);
    bool ok = false;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(h, i, &d); ++i) {
        wchar_t id[512]{};
        if (!SetupDiGetDeviceInstanceIdW(h, &d, id, 512, nullptr)) continue;
        if (_wcsicmp(id, instanceId.c_str()) != 0) continue;
        SP_PROPCHANGE_PARAMS p{};
        p.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        p.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
        p.StateChange = enable ? DICS_ENABLE : DICS_DISABLE;
        p.Scope = DICS_FLAG_GLOBAL;
        p.HwProfile = 0;
        if (SetupDiSetClassInstallParamsW(h, &d, &p.ClassInstallHeader, sizeof(p)))
            ok = (SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, h, &d) != FALSE);
        break;
    }
    SetupDiDestroyDeviceInfoList(h);
    return ok;
}

// 读注册表属性里的多字符串（REG_MULTI_SZ），判断是否含某个 ID
static bool PropContains(HDEVINFO h, SP_DEVINFO_DATA& d, DWORD prop, const wchar_t* needle) {
    DWORD bytes = 0;
    if (!SetupDiGetDeviceRegistryPropertyW(h, &d, prop, nullptr, nullptr, 0, &bytes)) {
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes == 0) return false;
    }
    if (bytes == 0) return false;
    std::vector<wchar_t> wbuf(bytes / sizeof(wchar_t) + 2, 0);
    if (!SetupDiGetDeviceRegistryPropertyW(h, &d, prop, nullptr, (PBYTE)wbuf.data(), bytes, nullptr))
        return false;
    size_t total = bytes / sizeof(wchar_t);
    size_t off = 0;
    while (off < total && wbuf[off]) {
        std::wstring s(&wbuf[off]);
        if (!s.empty() && s.find(needle) != std::wstring::npos) return true;
        off += s.size() + 1;
    }
    return false;
}

// 找 xHCI 控制器：PCI 类代码 0C0330（可扩展主机控制器）
// 注意: 该 ID 出现在「兼容 ID」(SPDRP_COMPATIBLEIDS) 里，硬件 ID 里没有 —— 两处都查
static std::vector<std::wstring> FindXhciControllers() {
    std::vector<std::wstring> out;
    HDEVINFO h = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (h == INVALID_HANDLE_VALUE) return out;
    SP_DEVINFO_DATA d{}; d.cbSize = sizeof(d);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(h, i, &d); ++i) {
        bool isXhci = PropContains(h, d, SPDRP_COMPATIBLEIDS, L"PCI\\CC_0C0330") ||
                      PropContains(h, d, SPDRP_HARDWAREID,    L"PCI\\CC_0C0330");
        if (!isXhci) continue;
        wchar_t id[512]{};
        if (SetupDiGetDeviceInstanceIdW(h, &d, id, 512, nullptr)) out.push_back(id);
    }
    SetupDiDestroyDeviceInfoList(h);
    return out;
}

static bool CameraUsable() {
    auto cams = EnumCameras();
    for (const auto& c : cams) if (c.started) return true;
    return false;
}

// 深度修复阶梯：清幽灵节点 -> 重扫 -> 重启根集线器 -> 循环 xHCI 控制器
// 硬约束：只动设备枚举，绝不修改任何电源设置（S0 / 睡眠 / 休眠 / WOL）
static bool DeepRepairLadder() {
    SetColor(C_HEAD); Line(L"");
    Line(L"  ---------- 深度修复（只动设备枚举，不改电源） ----------");
    SetColor(C_DEF);

    // 1) 清掉相机的幽灵节点（含 MI_00 / MI_02 / MI_04 与复合设备本体）
    int nCam = 0;
    for (const auto& id : EnumInstanceIds(kCamIdPart)) {
        if (RunHidden(L"pnputil.exe /remove-device \"" + id + L"\"")) {
            Line(L"      移除 %ls", id.c_str());
            nCam++;
        }
    }
    Line(L"  [1/4] 清理幽灵相机节点: %d 个", nCam);

    // 2) 清掉「设备描述符请求失败」占位节点
    int nBad = 0;
    for (const auto& id : EnumInstanceIds(L"VID_0000&PID_0002")) {
        if (RunHidden(L"pnputil.exe /remove-device \"" + id + L"\"")) {
            Line(L"      移除 %ls", id.c_str());
            nBad++;
        }
    }
    Line(L"  [2/4] 清理描述符失败节点: %d 个", nBad);
    Sleep(1500);

    // 3) 重新扫描
    Line(L"  [3/4] 重新扫描硬件 ...");
    RunHidden(L"pnputil.exe /scan-devices");
    Sleep(6000);
    if (CameraUsable()) { Ok(L"重扫后相机已回来"); return true; }

    // 4) 重启相机所在根集线器
    std::wstring hub;
    if (FindInstance(std::wstring(kRootHubHint) + L"\\", hub)) {
        if (RestartDevice(hub)) Ok((std::wstring(L"已重启根集线器: ") + hub).c_str());
        else Warn(L"重启根集线器失败");
    } else Warn(L"没找到 USB 根集线器");
    Sleep(6000);
    if (CameraUsable()) { Ok(L"重启集线器后相机已回来"); return true; }

    // 5) 最后一招：循环 xHCI 控制器（整条 USB 链路重新枚举）
    auto xh = FindXhciControllers();
    if (xh.empty()) { Warn(L"没找到 xHCI 控制器, 跳过最后一招"); }
    else {
        Line(L"  [!]  根集线器无效, 改为循环 USB xHCI 控制器（该控制器上的 USB 设备会短暂消失约 10 秒）");
        for (const auto& id : xh) {
            Line(L"      循环 %ls", id.c_str());
            SetDeviceEnabled(id, false);
            Sleep(5000);
            SetDeviceEnabled(id, true);
        }
        Sleep(10000);
        RunHidden(L"pnputil.exe /scan-devices");
        Sleep(5000);
    }
    if (CameraUsable()) return true;

    // 定性：端口上又冒出「描述符请求失败」占位节点 = 设备通电有响应，但答不出 USB 描述符
    if (!EnumInstanceIds(L"VID_0000&PID_0002").empty()) {
        Warn(L"端口上仍有「设备描述符请求失败」节点 → 设备通电, 但答不出 USB 描述符");
        Line(L"      这属于电气/接触层面（排线、连接器、供电），软件已无法再修。");
        Line(L"      建议：完全关机 → 拔电源 → 长按电源键 30-60 秒 → 开机；仍无效则为硬件故障。");
    }
    return false;
}

// ---------------- 诊断 ----------------
struct Diag {
    std::vector<DevItem> cams;
    bool  camPresent = false;
    bool  camStarted = false;
    FmtInfo fmt;
    bool  selSuspendKnown = false;
    DWORD selSuspend = 0;
    int   hubSwitchOk = 0;
};

static Diag RunDiag(bool withFormats) {
    Diag d;
    d.cams = EnumCameras();
    for (const auto& c : d.cams) { d.camPresent = true; if (c.started) d.camStarted = true; }
    if (withFormats && d.camPresent) d.fmt = QueryFormats();
    if (ReadUsbSelSuspend(d.selSuspend)) d.selSuspendKnown = true;
    DWORD v = 0; bool pre = false;
    if (RegGetDword(HKEY_LOCAL_MACHINE, kSvcUsbHub3, L"DisableSelectiveSuspend", v, pre) && pre && v == 1) d.hubSwitchOk++;
    if (RegGetDword(HKEY_LOCAL_MACHINE, kSvcUsbHub,  L"DisableSelectiveSuspend", v, pre) && pre && v == 1) d.hubSwitchOk++;
    return d;
}

static void PrintDiag(const Diag& d, bool showTitle = true) {
    if (showTitle) {
        SetColor(C_HEAD);
        Line(L"  ---------- 诊断 ----------");
        SetColor(C_DEF);
    }

    if (!d.camPresent) {
        Err(L"相机不在总线上");
    } else {
        for (const auto& c : d.cams) {
            if (c.started) Ok((c.desc + L" — 已启动").c_str());
            else Warn((c.desc + L" — 在位但未启动").c_str());
        }
    }
    if (d.camPresent) {
        if (d.fmt.count < 0) {
            wchar_t b[512];
            _snwprintf(b, 511, L"格式档位: 检测失败 (%ls; hr=0x%08lX init=0x%08lX)",
                       d.fmt.note.c_str(), d.fmt.hrCo, d.fmt.hrInit);
            Warn(b);
        }
        else if (d.fmt.count >= 5 && d.fmt.has1080)
            Ok(L"格式档位齐全(含 1920x1080) → 画面清晰");
        else {
            wchar_t buf[256];
            _snwprintf(buf, 255, L"相机被降级: 仅 %d 档格式, 含1080p=%ls → 画面模糊",
                       d.fmt.count, d.fmt.has1080 ? L"是" : L"否");
            Err(buf);
        }
    }
    if (d.selSuspendKnown) {
        if (d.selSuspend == 0) Ok(L"USB 选择性暂停 = 已禁用");
        else Warn(L"USB 选择性暂停 = 已启用(会诱发 DRIPS 删设备)");
    } else Info(L"USB 选择性暂停 = 读取失败");
    if (d.hubSwitchOk == 2) Ok(L"全局 hub 开关 = 2/2 已设");
    else Warn(L"全局 hub 开关 = 只设了 1 个或未设");
}

// ---------------- DRIPS 事件统计（回答"系统还在删我的相机吗"） ----------------
struct DripsInfo { int c196 = 0; int c205 = 0; int scanned = 0; std::wstring last196, last205; };

static std::wstring IsoToLocal(const std::wstring& iso) {
    if (iso.size() < 19) return iso;
    std::wstring s = iso.substr(0, 19);      // 2026-10-16T12:34:56
    size_t t = s.find(L'T');
    if (t != std::wstring::npos) s[t] = L' ';
    return s;
}

// 读 System 日志里 USBHUB3 的事件: ID196=某设备在空闲时耗电(相机就是),
// ID205=重新枚举"因电量不足被删除的 DRIPS 阻止设备"。这两个是根因的持续指标。
static std::wstring UtcCutoff(int hoursBack) {
    SYSTEMTIME st{}; GetSystemTime(&st);
    FILETIME ft{}; SystemTimeToFileTime(&st, &ft);
    ULARGE_INTEGER u; u.LowPart = ft.dwLowDateTime; u.HighPart = ft.dwHighDateTime;
    u.QuadPart -= (ULONGLONG)hoursBack * 3600ULL * 10000000ULL;
    ft.dwLowDateTime = u.LowPart; ft.dwHighDateTime = u.HighPart;
    FileTimeToSystemTime(&ft, &st);
    wchar_t b[64];
    _snwprintf(b, 63, L"%04d-%02d-%02d %02d:%02d:%02d",
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    return b;
}

static DripsInfo QueryDrips(int hoursBack = 24, int maxScan = 500) {
    DripsInfo r;
    std::wstring cutoff = (hoursBack > 0) ? UtcCutoff(hoursBack) : std::wstring();
    EVT_HANDLE h = EvtQuery(nullptr, L"System",
        L"*[System[Provider[@Name='Microsoft-Windows-USB-USBHUB3']]]",
        EvtQueryChannelPath | EvtQueryReverseDirection);
    if (!h) return r;
    EVT_HANDLE batch[32];
    DWORD got = 0;
    while (EvtNext(h, 32, batch, 5000, 0, &got) && got > 0) {
        for (DWORD i = 0; i < got; ++i) {
            r.scanned++;
            DWORD used = 0, prop = 0;
            EvtRender(nullptr, batch[i], EvtRenderEventXml, 0, nullptr, &used, &prop);
            if (used > 0) {
                std::vector<wchar_t> buf(used / sizeof(wchar_t) + 2, 0);
                if (EvtRender(nullptr, batch[i], EvtRenderEventXml, used, buf.data(), &used, &prop)) {
                    std::wstring xml = buf.data();
                    int id = 0;
                    size_t p = xml.find(L"<EventID>");
                    if (p != std::wstring::npos) id = _wtoi(xml.c_str() + p + 9);
                    std::wstring ts;
                    size_t q = xml.find(L"SystemTime='");
                    if (q != std::wstring::npos) {
                        size_t e2 = xml.find(L'\'', q + 12);
                        if (e2 != std::wstring::npos) ts = IsoToLocal(xml.substr(q + 12, e2 - (q + 12)));
                    }
                    bool inWin = cutoff.empty() || ts.empty() || (ts >= cutoff);
                    if (id == 196) { if (inWin) { r.c196++; if (r.last196.empty()) r.last196 = ts; } }
                    else if (id == 205) { if (inWin) { r.c205++; if (r.last205.empty()) r.last205 = ts; } }
                }
            }
            EvtClose(batch[i]);
        }
        if (r.scanned >= maxScan) break;
    }
    EvtClose(h);
    return r;
}

// ---------------- 帮助 ----------------
static void PrintHelp() {
    SetColor(C_HEAD);
    Line(L"  CamFix — 内置摄像头 诊断 / 恢复 / 修复");
    SetColor(C_DEF);
    Line(L"");
    Line(L"  用法:");
    Line(L"    CamFix.exe              一键修复: 诊断 → 需要时自动深度修复(正常时免 UAC、不打扰)");
    Line(L"    CamFix.exe --diag       只诊断, 免管理员");
    Line(L"    CamFix.exe --status     单行状态输出(供脚本/自启动判断)");
    Line(L"    CamFix.exe --recover    只重启相机设备(恢复画质)");
    Line(L"    CamFix.exe --deep       强制深度修复: 清幽灵节点 + 重扫 + 根集线器 + xHCI 循环");
    Line(L"    CamFix.exe --repair     完整修复: 备份 + 设备级参数 + 全局 hub 开关 + 电源计划 + 重启");
    Line(L"    CamFix.exe --restore    回滚到最近一次 backup\\*.reg");
    Line(L"    CamFix.exe --auto       静默自检(供开机自启): 写日志, 异常才弹窗");
    Line(L"    CamFix.exe --version    显示版本");
    Line(L"    CamFix.exe --no-pause   结束不等待按键");
    Line(L"");
    Line(L"  诊断项: 相机在场/已启动 · 格式档位(判「模糊」降级) · USB 选择性暂停 · 全局 hub 开关 · DRIPS 事件");
    Line(L"");
    Line(L"  日志: 与本程序同目录的 CamFix.log (超过 256 KB 自动轮转为 .old)");
    Line(L"");
}

// ---------------- 单行状态(供脚本/自启动调用) ----------------
static int PrintStatusLine() {
    Diag d = RunDiag(true);
    DripsInfo dr = QueryDrips();
    int overall = (d.camPresent && d.camStarted && d.fmt.count >= 5 && d.fmt.has1080 && d.hubSwitchOk == 2) ? 1 : 0;
    wchar_t b[512];
    _snwprintf(b, 511, L"OK=%d|cam=%d|started=%d|fmt=%d|1080p=%d|selsuspend=%ls|hub=%d|drips196=%d|drips205=%d",
               overall, d.camPresent ? 1 : 0, d.camStarted ? 1 : 0, d.fmt.count, d.fmt.has1080 ? 1 : 0,
               d.selSuspendKnown ? (d.selSuspend == 0 ? L"off" : L"on") : L"?",
               d.hubSwitchOk, dr.c196, dr.c205);
    Line(b);
    return 0;
}
// ---------------- 静默自检(供开机自启) ----------------
static int RunAuto() {
    Diag d = RunDiag(true);

    // 能免提权自愈的先自愈: 电源计划里的 USB 选择性暂停不需要管理员
    bool healed = false;
    if (d.selSuspendKnown && d.selSuspend != 0) {
        if (DisableUsbSelSuspend()) healed = true;
    }

    PrintDiag(d);                                  // 输出同时写入 CamFix.log
    if (healed) Line(L"  [自愈] USB 选择性暂停被复位, 已自动改回「已禁用」");

    DripsInfo dr = QueryDrips();
    Line(L"  DRIPS 事件(最近 %d 条 USBHUB3): ID196=%d 次, ID205=%d 次", dr.scanned, dr.c196, dr.c205);

    bool camBad = !d.camPresent ||
                  (d.fmt.count >= 0 && (d.fmt.count < 5 || !d.fmt.has1080));
    bool swBad = (d.hubSwitchOk < 2);

    if (camBad || swBad) {
        std::wstring msg = L"摄像头自检发现问题:\r\n\r\n";
        if (!d.camPresent) msg += L"· 相机不在总线上\r\n";
        else if (d.fmt.count >= 0 && (d.fmt.count < 5 || !d.fmt.has1080))
            msg += L"· 相机被降级(画面会模糊)\r\n";
        if (swBad) msg += L"· 全局 hub 开关未设全\r\n";
        msg += L"\r\n请双击桌面 CamFix.exe 修复(需要管理员)。\r\n\r\n详细日志: CamFix.log";
        MessageBoxW(nullptr, msg.c_str(), L"摄像头自检", MB_ICONWARNING | MB_TOPMOST | MB_SETFOREGROUND);
    }
    return (camBad || swBad) ? 1 : 0;
}

// ---------------- 主流程 ----------------
static bool g_noPause = false;
static void Pause() {
    if (g_noPause) return;
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    // 非交互(管道/重定向/无控制台)时不要等待按键, 否则自动化调用会永久挂住并锁住 exe
    if (!GetConsoleMode(in, &mode)) return;
    SetColor(C_DIM);
    Line(L"");
    Line(L"  按回车退出...");
    SetColor(C_DEF);
    char buf[8]; DWORD r = 0;
    ReadConsoleA(in, buf, sizeof(buf) - 1, &r, nullptr);
}

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(65001);
    g_out = GetStdHandle(STD_OUTPUT_HANDLE);
    // 一律留档到 exe 同目录 CamFix.log（提权后新窗口的输出也能回看）
    {
        wchar_t exePath[MAX_PATH]{};
        GetModuleFileNameW(nullptr, exePath, MAX_PATH);
        std::wstring lp = exePath;
        size_t sp = lp.find_last_of(L'\\');
        if (sp != std::wstring::npos) lp = lp.substr(0, sp + 1) + L"CamFix.log";
        // 日志轮转: 超过 256 KB 就改成 .old, 避免长期运行无限增长
        WIN32_FILE_ATTRIBUTE_DATA fad{};
        if (GetFileAttributesExW(lp.c_str(), GetFileExInfoStandard, &fad)) {
            ULONGLONG sz = ((ULONGLONG)fad.nFileSizeHigh << 32) | fad.nFileSizeLow;
            if (sz > 256 * 1024) {
                std::wstring oldp = lp + L".old";
                DeleteFileW(oldp.c_str());
                MoveFileW(lp.c_str(), oldp.c_str());
            }
        }
        g_log = CreateFileW(lp.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        SYSTEMTIME st{}; GetLocalTime(&st);
        wchar_t sep[160];
        _snwprintf(sep, 159, L"\n===== %04d-%02d-%02d %02d:%02d:%02d =====\n",
                   st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        WriteUtf8(g_log, sep);
    }

    bool diagOnly = false, doRepair = false, doRestore = false, doRecover = false, doDeep = false;
    bool showHelp = false, showVer = false, autoMode = false, statusOneLine = false;
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--diag")        diagOnly = true;
        else if (a == L"--repair")  doRepair = true;
        else if (a == L"--restore") doRestore = true;
        else if (a == L"--recover") doRecover = true;
        else if (a == L"--deep")    doDeep = true;          // 强制深度修复阶梯
        else if (a == L"--auto")    autoMode = true;        // 静默自检(供开机自启)
        else if (a == L"--status")  statusOneLine = true;   // 单行状态(供脚本调用)
        else if (a == L"--help" || a == L"-h" || a == L"/?") showHelp = true;
        else if (a == L"--version" || a == L"-v") showVer = true;
        else if (a == L"--no-pause") g_noPause = true;
    }
    if (autoMode) g_noPause = true;

    if (showVer) {
        Line(L"CamFix 1.2.1  (C++17 / Win32, MinGW-w64 build)");
        return 0;
    }
    if (showHelp) {
        PrintHelp();
        return 0;
    }

    // --auto: 静默自检模式(供开机自启)。不弹控制台、不等按键;
    //         能免提权自愈的(电源计划)自己修, 修不了的才弹窗提醒。
    if (statusOneLine) return PrintStatusLine();
    if (autoMode) return RunAuto();

    Line(L"");
    SetColor(C_HEAD);
    Line(L"  =====================================================");
    Line(L"   CamFix — 摄像头 诊断 / 恢复 / 修复   (C++ / Win32)");
    Line(L"  =====================================================");
    SetColor(C_DEF);
    Line(L"");

    // --repair / --restore 本来就要改系统, 直接提权
    if ((doRepair || doRestore) && !IsElevated()) {
        Info(L"该操作需要管理员权限, 正在申请提权(请在 UAC 窗口点「是」)...");
        if (!RelaunchElevated()) { Pause(); return 2; }
        return 0;
    }

    // ---- 诊断（免提权即可完成）----
    Diag d = RunDiag(true);

    // 无参数 / --recover: 先看诊断结果, 只有真需要动作才提权 —— 正常时不打扰
    if (!diagOnly && !doRepair && !doRestore) {
        bool needAction = doRecover || doDeep || !d.camPresent ||
                          (d.fmt.count >= 0 && (d.fmt.count < 5 || !d.fmt.has1080));
        if (needAction && !IsElevated()) {
            SetColor(C_WARN);
            Line(L"  检测到相机需要恢复, 正在申请管理员权限(请在 UAC 点「是」)...");
            SetColor(C_DEF);
            if (!RelaunchElevated()) { Pause(); return 2; }
            return 0;
        }
    }

    PrintDiag(d);

    // ---- DRIPS 事件: 回答"系统还在删我的相机吗" ----
    DripsInfo dr = QueryDrips();
    {
        wchar_t b[640];
        _snwprintf(b, 639, L"  DRIPS 事件(近 24h, USBHUB3): ID196=%d 次, 最新 %ls | ID205=%d 次, 最新 %ls",
                   dr.c196, dr.last196.empty() ? L"无" : dr.last196.c_str(),
                   dr.c205, dr.last205.empty() ? L"无" : dr.last205.c_str());
        SetColor(C_DIM); Line(b); SetColor(C_DEF);
    }


    if (diagOnly) {
        Line(L"");
        Info(L"[--diag] 只诊断, 未做任何修改。");
        Line(L"");
        Pause();
        return 0;
    }

    // ---- 回滚 ----
    if (doRestore) {
        SetColor(C_HEAD); Line(L"");
        Line(L"  ---------- 回滚 ----------"); SetColor(C_DEF);
        // 找最新备份
        WIN32_FIND_DATAW fd{};
        std::wstring pat = L"backup\\*.reg";
        HANDLE hf = FindFirstFileW(pat.c_str(), &fd);
        std::wstring newest;
        if (hf != INVALID_HANDLE_VALUE) {
            do { if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) newest = fd.cFileName; }
            while (FindNextFileW(hf, &fd));
            FindClose(hf);
        }
        if (newest.empty()) { Warn(L"没有找到 backup\\*.reg 备份, 无法回滚"); }
        else {
            std::wstring full = L"backup\\" + newest;
            Line(L"  使用备份: %ls", full.c_str());
            std::wstring cmd = L"reg.exe import \"" + full + L"\"";
            STARTUPINFOW si{}; si.cb = sizeof(si);
            PROCESS_INFORMATION pi{};
            std::vector<wchar_t> b(cmd.begin(), cmd.end()); b.push_back(0);
            if (CreateProcessW(nullptr, b.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
                WaitForSingleObject(pi.hProcess, 30000);
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
                Ok(L"已回滚注册表参数(重启后生效)");
            } else Warn(L"reg import 启动失败");
        }
        Line(L"");
        Pause();
        return 0;
    }

    int actions = 0;

    // ---- 恢复: 相机缺失或降级 就重启设备 ----
    bool degraded = d.camPresent && d.fmt.count >= 0 && (d.fmt.count < 5 || !d.fmt.has1080);
    bool missing  = !d.camPresent;
    if (doRecover || doRepair || degraded || missing || doDeep) {
        SetColor(C_HEAD); Line(L"");
        Line(L"  ---------- 动作 ----------"); SetColor(C_DEF);

        if (doRepair) {
            // 备份
            CreateDirectoryW(L"backup", nullptr);
            SYSTEMTIME st; GetLocalTime(&st);
            wchar_t name[128];
            _snwprintf(name, 127, L"backup\\usb_vid174f_backup_%04d%02d%02d_%02d%02d%02d.reg",
                       st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
            if (BackupRegistry(name)) Ok((std::wstring(L"注册表已备份 → ") + name).c_str());
            else Warn(L"注册表备份失败(不阻断修复)");

            auto keys = EnumCamRegKeys();
            int np = FixDeviceParams(keys);
            Line(L"  设备级参数写入 %d 处", np);
            int nh = FixGlobalHubSwitch();
            Line(L"  全局 hub 开关写入 %d 处", nh);
            if (nh > 0) Ok(L"USBHUB3 / usbhub 的 DisableSelectiveSuspend = 1");
            if (DisableUsbSelSuspend()) Ok(L"电源计划: USB 选择性暂停 → 已禁用");
            else Warn(L"电源计划写入失败");
            actions++;
        }

        if (missing || doDeep) {
            // 相机完全不在场 —— 走深度修复阶梯（清幽灵节点 / 重扫 / 根集线器 / xHCI）
            DeepRepairLadder();
            actions++;
        } else {

        // 重启复合设备(等效拔插), 需要管理员
        std::wstring compId;
        if (FindInstance(std::wstring(kCamIdParent) + L"\\", compId)) {
            if (RestartDevice(compId)) {
                Ok((std::wstring(L"已重启相机复合设备: ") + compId).c_str());
                actions++;
            } else Warn(L"重启相机复合设备失败");
        } else {
            Warn(L"没找到相机复合设备(设备可能完全不在场)");
        }

        // 全局兜底: 重启相机所在根集线器
        std::wstring hub;
        if (FindInstance(std::wstring(kRootHubHint) + L"\\", hub)) {
            if (RestartDevice(hub)) {
                Ok((std::wstring(L"已重启根集线器: ") + hub).c_str());
                actions++;
            }
        }

        Sleep(4000);
        // 让系统重新扫描
        DEVINST root = 0;
        if (CM_Locate_DevNodeW(&root, nullptr, CM_LOCATE_DEVNODE_NORMAL) == CR_SUCCESS)
            CM_Reenumerate_DevNode(root, CM_REENUMERATE_SYNCHRONOUS);
        Sleep(3000);
        }   // end: 相机在位时的常规恢复分支
    }

    // ---- 复验（只有真的做过动作才复验）----
    Diag d2 = d;
    if (actions > 0) {
        Line(L"");
        SetColor(C_HEAD);
        Line(L"  ---------- 复验 ----------");
        SetColor(C_DEF);
        d2 = RunDiag(true);

        bool stillBad = !d2.camPresent ||
                        (d2.fmt.count >= 0 && (d2.fmt.count < 5 || !d2.fmt.has1080));
        if (stillBad) {
            Line(L"  首次重启未恢复, 再试一次...");
            std::wstring comp2;
            if (FindInstance(std::wstring(kCamIdParent) + L"\\", comp2)) RestartDevice(comp2);
            std::wstring hub2;
            if (FindInstance(std::wstring(kRootHubHint) + L"\\", hub2)) RestartDevice(hub2);
            Sleep(5000);
            d2 = RunDiag(true);
        }
        PrintDiag(d2, false);
    }

    Line(L"");
    if (d2.camPresent && d2.camStarted && d2.fmt.count >= 5 && d2.fmt.has1080) {
        SetColor(C_OK);
        Line(L"  >>> 结果: 相机正常且画面清晰(1080p 档位齐全)");
    } else if (d2.camPresent && d2.camStarted) {
        SetColor(C_WARN);
        Line(L"  >>> 结果: 设备在位, 但档位仍不齐全 —— 建议完全关机再开机");
    } else {
        SetColor(C_ERR);
        Line(L"  >>> 结果: 相机仍未就绪（清节点/重扫/根集线器/xHCI 全部无效）");
        Line(L"      最后一步（物理操作，不改任何设置）：");
        Line(L"      完全关机 → 拔掉电源适配器 → 长按电源键 30-60 秒 → 插电开机");
    }
    SetColor(C_DEF);
    Line(L"");
    Line(L"  提示: 相机掉了就双击本程序, 它会自动跑到恢复为止。");
    Line(L"");
    Pause();
    return 0;
}
