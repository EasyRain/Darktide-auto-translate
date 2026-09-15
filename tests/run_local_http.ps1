# run_local_http.ps1 — end-to-end check of the HTTP result contract, fully offline.
#
# Serves tests\fixtures over plain HTTP on 127.0.0.1 and asserts that
#   a 200 body      is reported as success (exit 0)
#   a 404           is reported as failure (exit 3)
#
# This is the test that catches the classic bug of collapsing "no error" and "the
# 200 we received" into one value, which makes every successful request look like
# a failure. It needs no game, no proxy and no internet.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$port = 18080
$base = "http://127.0.0.1:$port"
$failures = 0

$server = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    python -m http.server $p --bind 127.0.0.1
} -ArgumentList "$root\tests\fixtures", $port

function Wait-Port($url, $seconds) {
    for ($i = 0; $i -lt ($seconds * 4); $i++) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return $true }
        } catch {
            # a 404 still proves the server is up
            if ($_.Exception.Response) { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

try {
    if (-not (Wait-Port "$base/clients5_ja.json" 15)) {
        Write-Host "FAIL  local server did not start"
        exit 1
    }

    & "$root\bin\at_cli.exe" http "$base/clients5_ja.json" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "PASS  HTTP 200 is reported as success"
    } else {
        Write-Host "FAIL  HTTP 200 was reported as failure (exit $LASTEXITCODE)"
        $failures++
    }

    & "$root\bin\at_cli.exe" http "$base/does-not-exist.json" | Out-Null
    if ($LASTEXITCODE -eq 3) {
        Write-Host "PASS  HTTP 404 is reported as failure"
    } else {
        Write-Host "FAIL  HTTP 404 was reported as success (exit $LASTEXITCODE)"
        $failures++
    }

    & "$root\bin\at_cli.exe" http "http://127.0.0.1:1/nothing" | Out-Null
    if ($LASTEXITCODE -eq 3) {
        Write-Host "PASS  an unreachable host is reported as failure"
    } else {
        Write-Host "FAIL  an unreachable host was reported as success (exit $LASTEXITCODE)"
        $failures++
    }
} finally {
    Stop-Job $server -ErrorAction SilentlyContinue
    Remove-Job $server -Force -ErrorAction SilentlyContinue
}

if ($failures -eq 0) {
    Write-Host ""
    Write-Host "http contract holds"
    exit 0
}
Write-Host ""
Write-Host "$failures check(s) failed"
exit 1
