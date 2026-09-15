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
