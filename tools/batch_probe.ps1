# batch_probe.ps1 -- run the batching A/B measurement against the real model.
#
# See tools/verify_batch.lua for what is being measured and why. This script only does
# the part that has to happen outside Lua: calling at_cli.exe, which needs the batch text
# to cross the Windows command line as Unicode.
#
#   pwsh -File tools/batch_probe.ps1 -Store <translations store> -ModelDir <models/small>
#
# Optional: -Lang (default zh-tw), -MaxItems (default 48), -ItemsPerBatch, -LuaJit, -Exe.
param(
    [Parameter(Mandatory = $true)][string]$Store,
    [Parameter(Mandatory = $true)][string]$ModelDir,
    [string]$Lang = "zh-tw",
    [int]$MaxItems = 48,
    [int]$ItemsPerBatch = 0,
    [string]$LuaJit = "luajit",
    [string]$Exe
)

$ErrorActionPreference = "Stop"
$tools = $PSScriptRoot
$repo = Split-Path -Parent $tools
$out = Join-Path $tools "out"
if (-not $Exe) { $Exe = Join-Path $repo "bin\at_cli.exe" }

New-Item -ItemType Directory -Force -Path $out | Out-Null

# UTF-8 without a BOM: the Lua side reads these files as raw bytes, and a BOM would end
# up inside the first string that is handed to the model.
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}

# Answers from an earlier run must not be mistaken for inputs later: "batch_1.out.txt"
# matches "batch_*.txt" too.
Remove-Item (Join-Path $out "*.out.txt") -ErrorAction SilentlyContinue

$prepareArgs = @((Join-Path $tools "verify_batch.lua"), "prepare", $Store, $Lang, $MaxItems)
if ($ItemsPerBatch -gt 0) { $prepareArgs += $ItemsPerBatch }
& $LuaJit @prepareArgs
if ($LASTEXITCODE -ne 0) { throw "prepare failed" }

# The baseline: the same masked strings, one at a time, in one process.
$texts = @(Get-Content (Join-Path $out "solo.txt") -Encoding utf8 | Where-Object { $_ -ne "" })
Write-Host "solo: $($texts.Count) string(s)"
Write-Utf8 (Join-Path $out "solo.out.txt") ((& $Exe queue $ModelDir $Lang @texts) -join "`r`n")
if ($LASTEXITCODE -ne 0) { throw "the solo run failed" }

# The batched runs: exactly the string dispatch() submits for each group.
foreach ($file in Get-ChildItem (Join-Path $out "batch_*.txt") | Where-Object { $_.Name -notlike "*.out.txt" } | Sort-Object Name) {
    $n = $file.BaseName -replace '^batch_', ''
    $text = (Get-Content $file.FullName -Raw -Encoding utf8).TrimEnd("`r", "`n")
    Write-Utf8 (Join-Path $out "batch_$n.out.txt") ((& $Exe model $ModelDir $Lang $text --src en) -join "`r`n")
    if ($LASTEXITCODE -ne 0) { throw "batch $n failed" }
    Write-Host "batch ${n}: done"
}

& $LuaJit (Join-Path $tools "verify_batch.lua") compare
