# run_checks.ps1 -- every check the README lists, one command, with a timing per check.
#
#   powershell -File tools\run_checks.ps1                  # all of them
#   powershell -File tools\run_checks.ps1 -Only store,glossary
#   powershell -File tools\run_checks.ps1 -Skip build      # skip the native/fixture checks
#   powershell -File tools\run_checks.ps1 -List
#
# Which check is which is in README.md ("Testing without launching the game"); this script is only
# the loop around them - it adds nothing to what they assert, and exits 0 only when all of them did.
param(
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [switch]$List
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# The game's Lua is LuaJIT (5.1): parsing with anything else accepts syntax it rejects. Same default
# as tools/lua_syntax_check.py, which also looks in D:\Tools\Lua\luajit\src.
$lua = if ($env:LUA_SYNTAX_LUAJIT) { $env:LUA_SYNTAX_LUAJIT } else { 'D:\Tools\Lua\luajit\src\luajit.exe' }
if (-not (Test-Path $lua)) { $lua = 'luajit' }

$checks = @(
    @{ name = 'syntax';    hint = 'LuaJIT parses all 15 Lua files';        cmd = { python tools\lua_syntax_check.py } },
    @{ name = 'exports';   hint = 'every at_* in the Lua CDEF is in the DLL'; cmd = { python tools\check_exports.py } },
    @{ name = 'loc';       hint = 'the mod UI: key counts, 12 languages';  cmd = { python tools\check_localization.py } },
    @{ name = 'online';    hint = 'providers, batching, options tree';     cmd = { & $lua tools\smoke_online.lua } },
    @{ name = 'export';    hint = 'the string-cache harvest';              cmd = { & $lua tools\smoke_export.lua } },
    @{ name = 'store';     hint = 'hand written vs machine entries';       cmd = { & $lua tools\smoke_store.lua } },
    @{ name = 'hud';       hint = 'the progress HUD splits long lines';    cmd = { & $lua tools\smoke_hud.lua } },
    @{ name = 'injector';  hint = 'merging into other mods, and back out'; cmd = { & $lua tools\smoke_injector.lua } },
    @{ name = 'options';   hint = 'option texts, translated and restored'; cmd = { & $lua tools\smoke_options_refresh.lua } },
    @{ name = 'glossary';  hint = 'the generated term table, end to end';  cmd = { & $lua tools\check_glossary.lua } },
    @{ name = 'layout';    hint = 'what the options screen will show';     cmd = { & $lua tools\check_options_layout.lua } },
    @{ name = 'stores';    hint = 'the played-with stores are clean';      cmd = { & $lua tools\check_stores.lua } },
    @{ name = 'core';      hint = 'at_cli selftest (native core)';         cmd = { & bin\at_cli.exe selftest } },
    @{ name = 'fixtures';  hint = 'real captured provider responses';      cmd = { cmd /c tests\run_fixtures.bat } }
)

if ($List) {
    $checks | ForEach-Object { '{0,-9} {1}' -f $_.name, $_.hint }
    exit 0
}

$failed = @()
$total = 0
foreach ($check in $checks) {
    if ($Only.Count -gt 0 -and $Only -notcontains $check.name) { continue }
    if ($Skip -contains $check.name) { continue }
    $total++
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & $check.cmd *> $null
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    $watch.Stop()
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    if ($code -eq 0) {
        '{0,-4} {1,-9} {2,5}s  {3}' -f 'ok', $check.name, $seconds, $check.hint
    } else {
        $failed += $check.name
        '{0,-4} {1,-9} {2,5}s  {3}  (exit {4})' -f 'FAIL', $check.name, $seconds, $check.hint, $code
    }
}

''
if ($failed.Count -gt 0) {
    '{0} of {1} check(s) FAILED: {2}' -f $failed.Count, $total, ($failed -join ', ')
    exit 1
}
"all $total check(s) passed"
exit 0
