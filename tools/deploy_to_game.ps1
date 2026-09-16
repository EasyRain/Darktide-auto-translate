# deploy_to_game.ps1 -- copy the mod's Lua into the game and prove it landed.
#
# Why this exists: the mod's Lua belongs in the *nested* path the .mod descriptor names -
#
#     mods/auto_translate/scripts/mods/auto_translate/auto_translate_data.lua
#
# while its data (bin/, models/, translations/) belongs at the mod's root. Copying the
# mod's Lua to the mod root therefore "succeeds" and does nothing: the game keeps loading
# the nested copy, which is exactly how a whole evening of fixes ran against a stale file
# (hashes of the two copies differed while every check here passed, because they were
# checking the root copy). This script writes to the path the descriptor names and then
# compares SHA-256 against the repository, so that mistake fails loudly.
#
#   powershell -NoProfile -File tools/deploy_to_game.ps1
#   powershell -NoProfile -File tools/deploy_to_game.ps1 -GameMods "E:\...\mods"

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$GameMods = "D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods"
)

$ErrorActionPreference = "Stop"

$name = "auto_translate"
$source = Join-Path $RepoRoot "scripts\mods\$name"
$dest = Join-Path $GameMods "$name\scripts\mods\$name"

if (-not (Test-Path $source)) { throw "no source at $source" }
if (-not (Test-Path (Join-Path $GameMods $name))) { throw "no mod folder at $(Join-Path $GameMods $name)" }

$descriptor = Join-Path $GameMods "$name\$name.mod"
if (Test-Path $descriptor) {
    $text = Get-Content $descriptor -Raw
    if ($text -notmatch "scripts/mods/$name/auto_translate") {
        throw "$descriptor does not point at scripts/mods/$name - check the layout before deploying"
    }
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $dest -Recurse -Force

# Anything the mod's Lua left at the mod root is a decoy, not a source: the descriptor and
# the module base path both say scripts/mods/<name>/. Reported, never deleted silently.
$decoys = Get-ChildItem -Path (Join-Path $GameMods $name) -File -Filter '*.lua'
$decoyModules = Join-Path $GameMods "$name\modules"

$failures = 0
foreach ($file in (Get-ChildItem -Path $source -Recurse -File)) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $target = Join-Path $dest $relative
    if (-not (Test-Path $target)) {
        Write-Output ("MISSING  {0}" -f $relative)
        $failures++
        continue
    }
    $a = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
    $b = (Get-FileHash $target -Algorithm SHA256).Hash
    $state = if ($a -eq $b) { "ok  " } else { "DIFF"; }
    if ($a -ne $b) { $failures++ }
    Write-Output ("{0} {1,-34} {2}" -f $state, $relative, $a.Substring(0, 16))
}

# The native core is built, not authored, but it changes whenever src/ does - and a game running
# an older DLL against newer Lua is exactly the silent mismatch this script exists to prevent
# (the CDEF names come from the DLL). It is 2 MB, so it is copied and verified like the Lua.
# models/ is still left alone: 1.4 GB, and the mod downloads it itself.
#
# A copy is skipped when the two files already match: the game keeps the DLL loaded while it runs, so
# overwriting an identical file fails with "used by another process" and makes a routine deploy look
# broken. Comparing first costs one hash and turns that into a no-op.
$coreSource = Join-Path $RepoRoot "bin\at_core.dll"
$coreDest = Join-Path $GameMods "$name\bin\at_core.dll"
if (Test-Path $coreSource) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $coreDest) | Out-Null
    $a = (Get-FileHash $coreSource -Algorithm SHA256).Hash
    $b = if (Test-Path $coreDest) { (Get-FileHash $coreDest -Algorithm SHA256).Hash } else { "" }
    if ($a -eq $b) {
        Write-Output ("{0} bin\{1,-31} {2}" -f "ok  ", "at_core.dll", $a.Substring(0, 16))
        Write-Output "      (already deployed, copy skipped - the game may be holding it open)"
    } else {
        Copy-Item $coreSource -Destination $coreDest -Force
        $b = (Get-FileHash $coreDest -Algorithm SHA256).Hash
        $state = if ($a -eq $b) { "ok  " } else { "DIFF"; }
        if ($a -ne $b) { $failures++ }
        Write-Output ("{0} bin\{1,-31} {2}" -f $state, "at_core.dll", $a.Substring(0, 16))
    }
}

# The data the Lua loads at runtime lives at the mod *root*, not next to the code: the glossary
# and the term key list. Those change as often as the code does (the glossary did, when language
# names were added), so they are synced and verified here too - "the file did not land" is
# otherwise invisible until a player notices the old data. bin/ and models/ are deliberately left
# alone: the DLL is built, the models are 1.4 GB, and neither belongs in a routine deploy.
#
# translations/export/ is not deployed either. Nothing reads it at runtime: it is the input to
# tools/build_glossary.py, it is 73 KB, and it lives in the repository (the only record of the
# game's terminology in twelve languages, which cannot be re-collected without launching the game
# once per language). A stale copy in the game folder is worse than none, because the exporter
# skips a language whose file already exists at the current key-list version.
# The descriptor itself carries the version the options screen shows, and the paths the game
# loads the mod from. It is one line of state that goes stale silently: a version bump in the
# repository used to reach the game folder only if someone copied it by hand, which the release
# packaging check caught (the zip said 0.2.0 and the deployed mod said 0.1.0).
$descriptorSource = Join-Path $RepoRoot "$name.mod"
$descriptorDest = Join-Path $GameMods "$name\$name.mod"
if (Test-Path $descriptorSource) {
    Copy-Item $descriptorSource -Destination $descriptorDest -Force
    $a = (Get-FileHash $descriptorSource -Algorithm SHA256).Hash
    $b = (Get-FileHash $descriptorDest -Algorithm SHA256).Hash
    $state = if ($a -eq $b) { "ok  " } else { "DIFF"; }
    if ($a -ne $b) { $failures++ }
    Write-Output ("{0} {1,-34} {2}" -f $state, "$name.mod", $a.Substring(0, 16))
}

$dataSource = Join-Path $RepoRoot "translations"
$dataDest = Join-Path $GameMods "$name\translations"
if (Test-Path $dataSource) {
    New-Item -ItemType Directory -Force -Path $dataDest | Out-Null
    Write-Output ""
    foreach ($file in (Get-ChildItem -Path $dataSource -File)) {
        Copy-Item $file.FullName -Destination $dataDest -Force
        $target = Join-Path $dataDest $file.Name
        $a = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
        $b = (Get-FileHash $target -Algorithm SHA256).Hash
        $state = if ($a -eq $b) { "ok  " } else { "DIFF"; }
        if ($a -ne $b) { $failures++ }
        Write-Output ("{0} translations\{1,-23} {2}" -f $state, $file.Name, $a.Substring(0, 16))
    }
    $skipped = Get-ChildItem -Path $dataSource -Directory | Where-Object { $_.Name -eq "export" }
    if ($skipped) {
        Write-Output "note: translations\export\ is not deployed - the game never reads it, and a stale copy blocks re-collection."
    }
}

if ($decoys -or (Test-Path $decoyModules)) {
    Write-Output ""
    Write-Output "note: stray Lua at the mod root (unused by the game, remove if it is a stale copy):"
    foreach ($d in $decoys) { Write-Output ("  " + $d.FullName.Replace($GameMods + "\", "")) }
    if (Test-Path $decoyModules) { Write-Output ("  " + $decoyModules.Replace($GameMods + "\", "")) }
}

Write-Output ""
if ($failures -eq 0) {
    Write-Output "deployed to $dest - every file matches the repository"
    Write-Output "Lua is read at startup: restart the game (reloading mods is not enough)."
    exit 0
}
Write-Output "$failures file(s) did not land"
exit 1
