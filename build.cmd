@echo off
rem ============================================================
rem  build.cmd — CamFix 构建入口（MinGW-w64）
rem
rem  用法:
rem    build.cmd            编译（默认）
rem    build.cmd release    编译 + 自检 + 部署到桌面
rem    build.cmd icon       重新生成图标，然后编译
rem    build.cmd all        icon + 编译 + 自检 + 部署（一条龙）
rem    build.cmd test       只跑自检（不编译）
rem    build.cmd clean      清理中间产物与日志
rem    build.cmd help       显示本说明
rem
rem  注意: 本文件必须保存为 GBK(936) 编码, 否则 cmd 读中文会乱码并破坏语法
rem ============================================================
setlocal
set "MINGW=D:\LE\AI\tools\mingw64\bin"
set "PY=C:\Users\zhedu\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
set "SRC=%~dp0"
set "TARGET=CamFix.exe"
set "CXXFLAGS=-std=c++17 -O2 -municode -mconsole -static -s -finput-charset=UTF-8 -Wno-cast-function-type"
set "LIBS=-lsetupapi -lcfgmgr32 -lole32 -loleaut32 -luuid -lstrmiids -lshlwapi -ladvapi32 -luser32 -lkernel32 -lwevtapi"

cd /d "%SRC%"
set "CMD=%~1"
if "%CMD%"=="" set "CMD=build"

if /i "%CMD%"=="build"   goto :cmd_build
if /i "%CMD%"=="icon"    goto :cmd_icon
if /i "%CMD%"=="release" goto :cmd_release
if /i "%CMD%"=="all"     goto :cmd_all
if /i "%CMD%"=="test"    goto :cmd_test
if /i "%CMD%"=="clean"   goto :cmd_clean
if /i "%CMD%"=="help"    goto :help
if /i "%CMD%"=="--help"  goto :help
echo [!] 未知命令: %CMD%
goto :help

:cmd_build
call :do_build
if errorlevel 1 goto :fail
echo.
echo [OK] 编译完成
goto :done

:cmd_icon
call :gen_icon
if errorlevel 1 goto :fail
call :do_build
if errorlevel 1 goto :fail
echo.
echo [OK] 图标 + 编译完成
goto :done

:cmd_release
call :do_build
if errorlevel 1 goto :fail
call :do_test
if errorlevel 1 goto :fail
call :do_deploy
if errorlevel 1 goto :fail
echo.
echo [OK] 全部完成
goto :done

:cmd_all
call :gen_icon
call :do_build
if errorlevel 1 goto :fail
call :do_test
if errorlevel 1 goto :fail
call :do_deploy
if errorlevel 1 goto :fail
echo.
echo [OK] 图标 + 编译 + 自检 + 部署 全部完成
goto :done

:cmd_test
if not exist "%TARGET%" (
  echo [!] 还没有 %TARGET%，先跑一次 build.cmd
  goto :fail
)
call :do_test
goto :done

:cmd_clean
echo.
echo [clean] 清理 ...
del /Q "%TARGET%" app.res.o CamFix_test.exe CamFix.log CamFix.log.old 2>nul
echo       [OK] 已清理（app.ico / icon-*.png 保留）
goto :done

rem ------------------------------------------------------------
:gen_icon
echo.
echo [icon] 生成图标 (make_icon.py) ...
if not exist "%PY%" (
  echo       [!] 找不到 Python: %PY%
  echo           跳过，继续用现有 app.ico
  exit /b 0
)
"%PY%" make_icon.py
if errorlevel 1 (
  echo       [!] 图标生成失败
  exit /b 1
)
echo       [OK] app.ico 已更新
exit /b 0

:do_build
echo.
if not exist "%MINGW%\g++.exe" (
  echo [!] 找不到编译器: %MINGW%\g++.exe
  exit /b 1
)
echo [1/2] 编译资源 app.res.o ...
"%MINGW%\windres.exe" app.rc -O coff -o app.res.o
if errorlevel 1 (
  echo       [!] windres 失败
  exit /b 1
)

echo [2/2] 编译链接 %TARGET% ...
"%MINGW%\g++.exe" %CXXFLAGS% -o "%TARGET%" main.cpp app.res.o %LIBS%
if errorlevel 1 (
  echo       [!] g++ 失败
  exit /b 1
)
for %%F in ("%TARGET%") do echo       [OK] %TARGET% = %%~zF 字节
exit /b 0

:do_test
echo.
echo [test] 自检 ...
"%TARGET%" --version
"%TARGET%" --status --no-pause
"%TARGET%" --diag --no-pause
exit /b 0

:do_deploy
echo.
echo [deploy] 部署到桌面 ...
set "TRY=0"
:deploy_retry
set /a TRY+=1
copy /Y "%TARGET%" "%USERPROFILE%\Desktop\%TARGET%" >nul 2>&1
if not errorlevel 1 goto :deploy_ok
if %TRY% GEQ 6 (
  echo       [!] 连续 6 次失败（文件被占用，通常是杀软在扫描新生成的 exe）
  echo           稍后手动复制:  %SRC%%TARGET%  --^>  桌面
  exit /b 1
)
echo       被占用，重试 %TRY%/6 ...
ping -n 3 127.0.0.1 >nul
goto :deploy_retry
:deploy_ok
echo       [OK] %USERPROFILE%\Desktop\%TARGET% 已更新
exit /b 0

:help
echo.
echo   CamFix 构建入口
echo.
echo     build.cmd            编译（默认）
echo     build.cmd release    编译 + 自检 + 部署到桌面
echo     build.cmd icon       重新生成图标，然后编译
echo     build.cmd all        icon + 编译 + 自检 + 部署
echo     build.cmd test       只跑自检
echo     build.cmd clean      清理中间产物与日志
echo.
echo   编译器: %MINGW%\g++.exe
echo   产物:   %SRC%%TARGET%
echo.
goto :done

:fail
echo.
echo [X] 构建失败
endlocal
exit /b 1

:done
endlocal
exit /b 0
