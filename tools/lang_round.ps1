# lang_round.ps1 -- run one term-collection round: set the game's language, launch it, wait for the
# export, stop it again.
#
# Why: a full collection is twelve rounds, because the game loads one language at a time and the
# strings only exist at runtime (the bundles are compressed - a scan of all 15,425 of them found no
# plain-text string). Switching the language by hand means the Steam UI, per language, twelve times.
# Two files can do it instead:
#
# The game's own settings were measured first (2026-09-16) and are *not* the switch: with
# language_id set to "en" the game still ran in zh-cn and wrote "zh-cn" back into user_settings.config,
# so that file records the language Steam reports rather than deciding it. The Steam per-game setting
# in the app manifest is the one the Steam UI writes, which is what -Via steam edits.
#
# The launcher then needs one click before the game starts, so a round is: run this (it switches the
# language and waits), click Play, and it stops the game once the mod has written its export.
#
#   powershell -NoProfile -File tools/lang_round.ps1 -Language en
#   powershell -NoProfile -File tools/lang_round.ps1 -Language ja -NoLaunch      # only switch + report
#
# Nothing here touches the repository: after the rounds, run tools/import_exports.py.

param(
    [Parameter(Mandatory = $true)][string]$Language,   # the game's own code: en, zh-cn, zh-tw, ja, ...
    [ValidateSet("config", "steam")][string]$Via = "steam",
    [string]$Settings = "$env:APPDATA\Fatshark\Darktide\user_settings.config",
    [string]$Logs = "$env:APPDATA\Fatshark\Darktide\console_logs",
    [string]$SteamApps = "D:\Steam\steamapps",
    [string]$AppId = "1361210",
    [int]$TimeoutSeconds = 300,
    [int]$SettleSeconds = 12,
    [switch]$NoLaunch,
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"

# The game's codes, and what Steam calls the same language.
$GAME_CODES = @("en", "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br")
$STEAM_CODES = @{
    "en" = "english"; "zh-cn" = "schinese"; "zh-tw" = "tchinese"; "ja" = "japanese"
    "ko" = "koreana"; "ru" = "russian"; "de" = "german"; "fr" = "french"
    "es" = "spanish"; "it" = "italian"; "pl" = "polish"; "pt-br" = "brazilian"
}

if ($GAME_CODES -notcontains $Language) {
    throw "unknown language '$Language' - expected one of $($GAME_CODES -join ', ')"
}

function Set-SettingLine {
    param([string]$Path, [string]$Name, [string]$Value, [string]$Indent)
    $raw = [IO.File]::ReadAllBytes($Path)
    $bom = $raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($raw)
    if ($bom) { $text = $text.Substring(1) }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $text -split "`r?`n"
    $pattern = '^' + [regex]::Escape($Indent) + [regex]::Escape($Name) + '\s*=\s*"[^"]*"\s*$'
    $changed = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = "$Indent$Name = `"$Value`""
            $changed++
        }
    }
    if ($changed -eq 0) { throw "no '$Name' line at indent '$Indent' in $Path" }
    $out = [Text.Encoding]::UTF8.GetBytes(($lines -join $newline))
    [IO.File]::WriteAllBytes($Path, $out)
    return $changed
}

Write-Output "round: $Language (via $Via)"

if ($Via -eq "config") {
    # The game's own setting: a top-level line, no indentation. detected_user_settings carries one too
    # (the value the game guessed at first launch), so the indentation is what tells them apart.
    Copy-Item $Settings "$Settings.bak-langround" -Force
    $n = Set-SettingLine -Path $Settings -Name "language_id" -Value $Language -Indent ""
    Write-Output "  set language_id = `"$Language`" ($n line(s)) in $Settings"
} else {
    $manifest = Join-Path $SteamApps "appmanifest_$AppId.acf"
    Copy-Item $manifest "$manifest.bak-langround" -Force
    $n = Set-SettingLine -Path $manifest -Name "language" -Value $STEAM_CODES[$Language] -Indent "`t"
    Write-Output "  set UserConfig language = `"$($STEAM_CODES[$Language])`" ($n line(s)) in $manifest"
    Write-Output "  note: Steam owns this file while it runs and may write its own value back"
}

if ($NoLaunch) {
    Write-Output "  -NoLaunch: launch the game yourself, then check that the mod writes export\$Language.lua"
    exit 0
}

$started = Get-Date
Write-Output "  launching app $AppId ..."
Start-Process "steam://rungameid/$AppId"

$found = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $log = Get-ChildItem $Logs -Filter "console-*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $started } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { continue }
    $hit = Select-String -Path $log.FullName -Pattern "exported (\d+) term\(s\) for '([^']+)'" -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if ($hit) {
        $found = $hit.Matches[0]
        Write-Output "  mod says: $($hit.Line.Trim())"
        break
    }
    $probe = Select-String -Path $log.FullName -Pattern "language probe:" -ErrorAction SilentlyContinue
    if ($probe) { Write-Output "  (the language probe block is in this log)" }
}

if (-not $found) {
    Write-Output "  no export line within $TimeoutSeconds s - see the newest log in $Logs"
    exit 1
}

$exported = $found.Groups[2].Value
$count = $found.Groups[1].Value
if ($exported -eq $Language) {
    Write-Output "  OK: the game ran in '$Language' - $count term(s) exported"
} else {
    Write-Output "  MISMATCH: asked for '$Language', the game exported '$exported'"
    Write-Output "  -> the setting this route edits is not the one the game obeys"
}

Start-Sleep -Seconds $SettleSeconds
if (-not $KeepRunning) {
    $game = Get-Process Darktide -ErrorAction SilentlyContinue
    if ($game) {
        Write-Output "  stopping the game (pid $($game.Id -join ', '))"
        $game | Stop-Process -Force
    } else {
        Write-Output "  the game already exited"
    }
}

if ($Via -eq "config") {
    $after = (Select-String -Path $Settings -Pattern '^language_id\s*=\s*"([^"]+)"' | Select-Object -Last 1)
    if ($after) { Write-Output "  settings still say language_id = $($after.Matches[0].Groups[1].Value)" }
}

Write-Output ""
Write-Output "next: run the other languages, then tools/import_exports.py + build tools"
