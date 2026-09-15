@echo off
REM Builds a 64-bit LuaJIT from the source tree next to this repo's tooling.
REM
REM Why x64 matters here: the game's LuaJIT is 64-bit and so is at_core.dll (checked:
REM machine 0x8664), so a 32-bit luajit.exe cannot load the DLL at all - it fails with
REM "%1 is not a valid Win32 application". Everything that touches the core through the
REM FFI (the downloader, the model entry points) can only be tested outside the game with
REM a matching build. Plain script checks (tools\smoke_online.lua, tools\lua_syntax_check.py)
REM work either way.
REM
REM   tools\build_luajit64.bat [source-dir]
REM
REM Default source dir: D:\Tools\Lua\luajit (the tree the tooling was set up from). The
REM build happens in place, so the previous binaries are copied aside as luajit32.exe /
REM lua51_32.dll the first time this runs.
setlocal

set SRC=%~1
if "%SRC%"=="" set SRC=D:\Tools\Lua\luajit

if not exist "%SRC%\src\msvcbuild.bat" (
  echo FAILED: "%SRC%\src\msvcbuild.bat" not found - pass the LuaJIT source directory
  exit /b 1
)

call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo FAILED: could not initialise the x64 MSVC environment
  exit /b 1
)

if not exist "%SRC%\src\luajit32.exe" (
  if exist "%SRC%\src\luajit.exe" copy /y "%SRC%\src\luajit.exe" "%SRC%\src\luajit32.exe" >nul
  if exist "%SRC%\src\lua51.dll"  copy /y "%SRC%\src\lua51.dll"  "%SRC%\src\lua51_32.dll" >nul
)

cd /d "%SRC%\src"
call msvcbuild.bat
if errorlevel 1 (
  echo FAILED: msvcbuild.bat
  exit /b 1
)

echo.
echo built %SRC%\src\luajit.exe (x64)
endlocal
