@echo off
REM Builds bin\at_core.dll (the native core, now including the offline NLLB engine)
REM and bin\at_cli.exe (out-of-game test tool).
REM
REM The CTranslate2 and SentencePiece libraries live outside this repository, in
REM <workspace>\third_party. They are static (/MT, matching the compiler default
REM here) so the DLL stays self-contained: a DLL's own directory is NOT searched
REM for its dependencies when it is loaded, so shipping a ctranslate2.dll beside
REM at_core.dll would not reliably work inside the game.
REM
REM The .c and .cpp sources are compiled separately on purpose:
REM   * CTranslate2's headers need C++17 and exceptions (/std:c++17 /EHsc),
REM     which the plain C sources must not see;
REM   * at_model.c and at_model.cpp would otherwise both claim at_model.obj and
REM     one would silently overwrite the other.
setlocal

call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo FAILED: could not initialise the MSVC environment
  exit /b 1
)

set TP=%~dp0..\..\third_party

if not exist bin mkdir bin

if not exist "%TP%\ct2_libs.bat" (
  echo FAILED: "%TP%\ct2_libs.bat" not found
  echo         run third_party\build_probe.ps1's generator or third_party\gen_libs.ps1 first
  exit /b 1
)
call "%TP%\ct2_libs.bat"

REM sentencepiece ships its abseil fallback and protobuf-lite sources in-tree;
REM the include roots below are the ones its own CMakeLists.txt uses.
set INCLUDES=/I "%TP%\CTranslate2\include" ^
 /I "%TP%\sentencepiece-0199\src" ^
 /I "%TP%\sentencepiece-0199\src\builtin_pb" ^
 /I "%TP%\sentencepiece-0199\third_party" ^
 /I "%TP%\sentencepiece-0199\third_party\protobuf-lite"

del /q *.obj 2>nul

cl /nologo /O2 /c /utf-8 /DAT_CORE_BUILD %INCLUDES% ^
   src\at_core.c src\at_json.c src\at_online.c src\at_model.c
if errorlevel 1 (
  echo FAILED: compiling the C sources
  exit /b 1
)

cl /nologo /O2 /c /utf-8 /EHsc /std:c++17 /DAT_CORE_BUILD %INCLUDES% ^
   /Fo:at_model_cpp.obj src\at_model.cpp
if errorlevel 1 (
  echo FAILED: compiling at_model.cpp
  exit /b 1
)

link /nologo /DLL /OUT:bin\at_core.dll /IMPLIB:bin\at_core.lib ^
   at_core.obj at_json.obj at_online.obj at_model.obj at_model_cpp.obj ^
   winhttp.lib advapi32.lib %CT2_LIBS%
if errorlevel 1 (
  echo FAILED: linking at_core.dll
  exit /b 1
)

cl /nologo /O2 /utf-8 src\at_cli.c /Fe:bin\at_cli.exe /link bin\at_core.lib shell32.lib
if errorlevel 1 (
  echo FAILED: at_cli.exe
  exit /b 1
)

del /q *.obj 2>nul
del /q at_cli.obj 2>nul

echo built bin\at_core.dll and bin\at_cli.exe
endlocal
