@echo off
REM Parses the real captured provider responses in tests\fixtures with the same
REM code the game uses. No network, no game. Run after touching src\at_online.c.
REM
REM The fixtures are raw bodies fetched from the live services, so this catches
REM "the API changed shape" and "the service reports a refusal as a success".
setlocal
cd /d "%~dp0.."

set FAILED=0

call :check google_clients5 tests\fixtures\clients5_ja.json
call :check google_clients5 tests\fixtures\clients5_zhcn.json
call :check google_clients5 tests\fixtures\clients5_auto.json
call :check google_clients5 tests\fixtures\clients5_special.json
call :check mymemory       tests\fixtures\mymemory_ja.json
call :check mymemory       tests\fixtures\mymemory_entity.json
REM Real DeepL responses, captured with a free-tier key (no key in the fixtures).
call :check deepl          tests\fixtures\deepl_zhcn.json
call :check deepl          tests\fixtures\deepl_ja.json

REM These must be *rejected*: the service reports a refusal with status 200.
call :expect_fail mymemory tests\fixtures\mymemory_quota.json
REM DeepL sends errors as {"message":...} with a 4xx status.
call :expect_fail deepl    tests\fixtures\deepl_badlang.json

if "%FAILED%"=="0" (
  echo.
  echo all fixtures behaved as expected
  endlocal & exit /b 0
)
echo.
echo %FAILED% fixture(s) did not behave as expected
endlocal & exit /b 1

:check
bin\at_cli.exe parse %1 %2 >nul 2>&1
if errorlevel 1 (
  echo FAIL  %1 %2  should have parsed
  set /a FAILED+=1
) else (
  echo PASS  %1 %2
)
exit /b 0

:expect_fail
bin\at_cli.exe parse %1 %2 >nul 2>&1
if errorlevel 1 (
  echo PASS  %1 %2  correctly rejected
) else (
  echo FAIL  %1 %2  was accepted but is a refusal
  set /a FAILED+=1
)
exit /b 0
