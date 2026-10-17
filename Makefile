# ============================================================
#  Makefile — CamFix 构建（MinGW-w64）
#
#  本机没有 sh.exe，mingw32-make 用 cmd.exe 作 shell，
#  因此这里全部使用 Windows 命令（copy/del），不要写 rm/cp/stat。
#
#  用法:
#    mingw32-make            编译
#    mingw32-make icon       重新生成图标
#    mingw32-make test       自检（--version / --status / --diag）
#    mingw32-make release    编译 + 部署到桌面
#    mingw32-make all        icon + 编译 + 测试 + 部署
#    mingw32-make clean      清理中间产物
#    mingw32-make help       显示用法
# ============================================================

CXX      ?= D:/LE/AI/tools/mingw64/bin/g++.exe
WINDRES  ?= D:/LE/AI/tools/mingw64/bin/windres.exe
PY       ?= C:/Users/zhedu/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

TARGET    = CamFix.exe
SRC       = main.cpp
RES       = app.res.o
RC        = app.rc
DESKTOP   = C:/Users/zhedu/Desktop

CXXFLAGS  = -std=c++17 -O2 -municode -mconsole -static -s \
            -finput-charset=UTF-8 -Wno-cast-function-type
LIBS      = -lsetupapi -lcfgmgr32 -lole32 -loleaut32 -luuid -lstrmiids \
            -lshlwapi -ladvapi32 -luser32 -lkernel32 -lwevtapi

.PHONY: all build icon test release clean help

all: icon build test release

build: $(TARGET)

$(RES): $(RC) app.ico app.manifest
	$(WINDRES) $(RC) -O coff -o $@
	@echo [OK] $(RES)

$(TARGET): $(SRC) $(RES)
	$(CXX) $(CXXFLAGS) -o $@ $(SRC) $(RES) $(LIBS)
	@echo [OK] $(TARGET) built

icon:
	$(PY) make_icon.py

test: $(TARGET)
	$(TARGET) --version
	$(TARGET) --status --no-pause
	$(TARGET) --diag --no-pause

release: $(TARGET)
	copy /Y $(subst /,\,$(TARGET)) "$(subst /,\,$(DESKTOP))\$(TARGET)" >NUL
	@echo [OK] deployed to Desktop

clean:
	-del /Q $(TARGET) $(RES) CamFix_test.exe CamFix.log CamFix.log.old 2>NUL
	@echo [OK] cleaned

help:
	@echo make / make build   - compile
	@echo make icon           - regenerate icon (make_icon.py)
	@echo make test           - self test
	@echo make release        - compile + deploy to Desktop
	@echo make all            - icon + build + test + deploy
	@echo make clean          - clean artifacts
