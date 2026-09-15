# model_probe.ps1 -- compare two offline models on the same real strings.
#
# Answers the question "is the bigger model actually better for our text, and what does
# it cost", instead of assuming that more parameters win. Everything goes through the
# real code path: the real planner, the real prompts, the real split/restore/guard
# logic (tools/verify_batch.lua), and the real models.
#
#   powershell -File tools\model_probe.ps1 -Store tools\out\probe-store.lua `
#            -ModelA <models\small> -ModelB <models\large> [-Lang zh-tw] [-MaxItems 135]
#
# ModelA is the current engine, ModelB the candidate. The full per-string table lands in
# tools\out\model-compare.txt; the console prints the summary plus everything that
# differs. Latency is measured with `model --async` (which prints the poll time, so the
# process start and model load are not part of the number).
param(
    [Parameter(Mandatory = $true)][string]$Store,
    [Parameter(Mandatory = $true)][string]$ModelA,
    [Parameter(Mandatory = $true)][string]$ModelB,
    [string]$Lang = "zh-tw",
    [int]$MaxItems = 135,
    [int]$ItemsPerBatch = 8,
    [string]$LuaJit = "luajit",
    [string]$Exe
)

$ErrorActionPreference = "Stop"
$tools = $PSScriptRoot
$repo = Split-Path -Parent $tools
$out = Join-Path $tools "out"
if (-not $Exe) { $Exe = Join-Path $repo "bin\at_cli.exe" }

New-Item -ItemType Directory -Force -Path $out | Out-Null

# UTF-8 without a BOM: the Lua side reads these files as raw bytes.
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}
function Read-Utf8([string]$path) {
    return (Get-Content $path -Raw -Encoding utf8).TrimEnd("`r", "`n")
}

Remove-Item (Join-Path $out "batch_*.out.txt") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $out "batch_*.txt") -ErrorAction SilentlyContinue

& $LuaJit (Join-Path $tools "verify_batch.lua") prepare $Store $Lang $MaxItems $ItemsPerBatch
if ($LASTEXITCODE -ne 0) { throw "prepare failed" }

$solo = @(Get-Content (Join-Path $out "solo.txt") -Encoding utf8 | Where-Object { $_ -ne "" })
$batches = @(Get-ChildItem (Join-Path $out "batch_*.txt") | Where-Object { $_.Name -notlike "*.out.txt" } | Sort-Object Name)

function Measure-Model([string]$tag, [string]$modelDir) {
    $dir = Join-Path $out $tag
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Utf8 (Join-Path $dir "solo.out.txt") ((& $Exe queue $modelDir $Lang @solo) -join "`r`n")
    if ($LASTEXITCODE -ne 0) { throw "the solo run for $tag failed" }
    $soloSeconds = $sw.Elapsed.TotalSeconds

    $sw.Restart()
    foreach ($file in $batches) {
        $n = $file.BaseName -replace '^batch_', ''
        Write-Utf8 (Join-Path $dir "batch_$n.out.txt") ((& $Exe model $modelDir $Lang (Read-Utf8 $file.FullName) --src en) -join "`r`n")
        if ($LASTEXITCODE -ne 0) { throw "batch $n for $tag failed" }
    }
    $batchSeconds = $sw.Elapsed.TotalSeconds

    # Latency without the process start and the model load: `model --async` prints how
    # long the poll loop waited for the answer.
    $short = (& $Exe model $modelDir $Lang "Reload Speed" --src en --async) -join "`n"
    $shortMs = if ($short -match "polled\s*:\s*after ~(\d+) ms") { $matches[1] } else { "?" }
    $batchText = Read-Utf8 $batches[0].FullName
    $batchItems = ([regex]::Matches($batchText, '\[\d+\]')).Count
    $batchOut = (& $Exe model $modelDir $Lang $batchText --src en --async) -join "`n"
    $batchMs = if ($batchOut -match "polled\s*:\s*after ~(\d+) ms") { $matches[1] } else { "?" }

    Write-Host ("{0}: solo {1:N1}s for {2} string(s) = {3:N0} ms/string incl. load; batches {4:N1}s for {5} batch(es); poll: 1 short string {6} ms, batch of {7} {8} ms" -f `
        $tag, $soloSeconds, $solo.Count, ($soloSeconds * 1000 / $solo.Count), $batchSeconds, $batches.Count, $shortMs, $batchItems, $batchMs)
}

Measure-Model "a" $ModelA
Measure-Model "b" $ModelB

& $LuaJit (Join-Path $tools "verify_batch.lua") compare-models a b
