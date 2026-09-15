@echo off
REM Builds bin\at_core.dll (the native core) and bin\at_cli.exe (out-of-game test tool).
REM Requires Visual Studio 2022 with the Windows SDK.
setlocal

call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo FAILED: could not initialise the MSVC environment
  exit /b 1
)

if not exist bin mkdir bin

cl /nologo /O2 /LD /utf-8 /DAT_CORE_BUILD src\at_core.c src\at_json.c src\at_online.c ^
   /Fe:bin\at_core.dll /link winhttp.lib advapi32.lib
if errorlevel 1 (
  echo FAILED: at_core.dll
  exit /b 1
)

cl /nologo /O2 /utf-8 src\at_cli.c /Fe:bin\at_cli.exe /link bin\at_core.lib
if errorlevel 1 (
  echo FAILED: at_cli.exe
  exit /b 1
)

del /q bin\at_core.obj bin\at_core.exp at_cli.obj at_json.obj at_online.obj 2>nul
del /q *.obj 2>nul

echo built bin\at_core.dll and bin\at_cli.exe
endlocal
