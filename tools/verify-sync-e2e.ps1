# Pek.ZIP sync end-to-end check (fake platform, no network needed)
#
# What it proves (the whole upgrade chain, which unit tests do not cover):
#   1. catalog.json parse -> sha256 verify -> zip download -> extract -> install
#   2. second sync detects a newer version and installs it
#   3. old versions are cleaned (keep = 1)
#
# Requirements: python on PATH (used as a static HTTP server), zig build already run.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-sync-e2e.ps1
# Exit:   0 = all assertions passed, 1 = failure.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$zpk = Join-Path $repo 'zig-out\bin\zpk.exe'
if (-not (Test-Path $zpk)) {
    Write-Output "SKIP: $zpk not found - run 'zig build' first"
    exit 1
}

$root = Join-Path $repo '.zig-cache\e2e-verify'
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$root\srv\components", "$root\base\Config", "$root\base\data", "$root\tmp1", "$root\tmp2" | Out-Null

# Kill leftover servers from a previous interrupted run (a stale server serving an old
# directory makes the first sync see the wrong catalog - that is exactly what happened
# once and silently broke the install-v1 assertion).
function Stop-ServerOnPort([int]$p) {
    $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }
}

# pick a free port
$port = 0
for ($p = 19000; $p -lt 19100; $p++) {
    if (-not (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)) { $port = $p; break }
}
if ($port -eq 0) { Write-Output 'FAIL  port-pick  no free port in 19000-19099'; exit 1 }
Stop-ServerOnPort $port

# PS 5.1: a native command writing to stderr is treated as a terminating error when
# $ErrorActionPreference = 'Stop'. Temporarily switch to Continue around calls.
function Invoke-Zpk([string[]]$zpkArgs, [string]$outFile) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($outFile) {
            & $zpk @zpkArgs 2>&1 | Out-File -FilePath $outFile -Encoding utf8
        } else {
            & $zpk @zpkArgs 2>&1 | Out-Null
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
}

# 1) two xdb builds with different region text, packaged as platform zips
Invoke-Zpk @('mkxdb', "$root\tmp1\ip2region_v4.xdb", 'CN|Jiangsu|Nanjing|telecom|CN') $null | Out-Null
Invoke-Zpk @('mkxdb', "$root\tmp2\ip2region_v4.xdb", 'CN|Guangdong|Shenzhen|mobile|CN') $null | Out-Null
Compress-Archive -Path "$root\tmp1\ip2region_v4.xdb" -DestinationPath "$root\srv\components\ip2region-v4-2026.10-any.zip" -Force
Compress-Archive -Path "$root\tmp2\ip2region_v4.xdb" -DestinationPath "$root\srv\components\ip2region-v4-2026.11-any.zip" -Force

$h10 = (Get-FileHash "$root\srv\components\ip2region-v4-2026.10-any.zip" -Algorithm SHA256).Hash.ToLower()
$h11 = (Get-FileHash "$root\srv\components\ip2region-v4-2026.11-any.zip" -Algorithm SHA256).Hash.ToLower()

# 2) placeholder mmdb files so only ip2region-v4 goes through the download path
Set-Content "$root\base\data\dbip-city-lite.mmdb" -Value 'placeholder' -Encoding ascii
Set-Content "$root\base\data\dbip-asn-lite.mmdb" -Value 'placeholder' -Encoding ascii

$cfg = "StoreUrl = `"http://127.0.0.1:$port`"`nPubKey = `"`"`nAutoEnroll = false`nDownloadV6 = false`nDataDir = `"data`"`nCacheDir = `"cache`"`nStateDir = `"client`"`nCatalogMaxAge = 0`nHttpTimeoutMs = 5000`n"
[System.IO.File]::WriteAllText("$root\base\Config\Ip.toml", $cfg, (New-Object System.Text.UTF8Encoding($false)))

function Write-Catalog([string]$version, [string]$hash) {
    $entry = [ordered]@{
        id = 'ip2region-v4'; name = 'ip2region v4'; category = 'ip-database'
        version = $version; target = 'any'; sha256 = $hash
        url = "/components/ip2region-v4-$version-any.zip"; sizeKB = 4; notes = 'e2e'
    }
    $json = [ordered]@{ components = @($entry) } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText("$root\srv\components\catalog.json", $json, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Catalog '2026.10' $h10

# 3) start the fake platform
$srv = Start-Process python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', "$root\srv" -PassThru -WindowStyle Hidden
try {
    # wait until the fake platform actually answers (python startup is not instant)
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/components/catalog.json" -UseBasicParsing -TimeoutSec 2
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $ready) { Write-Output "FAIL  server-ready  fake platform did not answer on port $port"; exit 1 }

    # 4) first sync installs 2026.10
    $code1 = Invoke-Zpk @('sync', '--base', "$root\base") "$root\sync1.txt"
    $v10 = Test-Path "$root\base\cache\ip2region-v4\2026.10"

    # 5) platform publishes 2026.11, sync again
    Write-Catalog '2026.11' $h11
    $code2 = Invoke-Zpk @('sync', '--base', "$root\base") "$root\sync2.txt"
    $v11 = Test-Path "$root\base\cache\ip2region-v4\2026.11"
    $v10_after = Test-Path "$root\base\cache\ip2region-v4\2026.10"

    # 6) the freshly installed data must actually be used by lookups (hot swap works)
    $code3 = Invoke-Zpk @('lookup', '--base', "$root\base", '114.114.114.114') "$root\lookup.txt"
    $lk = Get-Content "$root\lookup.txt" -Encoding UTF8 -Raw

    # 7) catalog cache must be reusable inside the TTL window (no network, no re-download).
    #    This guards a real bug found on 2026-11-19: the sig slice was freed before being
    #    cached (dangling pointer -> garbage sig -> cache never trusted -> 85 KB refetch every run).
    $cfg_ttl = $cfg -replace 'CatalogMaxAge = 0', 'CatalogMaxAge = 3600'
    [System.IO.File]::WriteAllText("$root\base\Config\Ip.toml", $cfg_ttl, (New-Object System.Text.UTF8Encoding($false)))
    $catalog_before = (Get-FileHash "$root\srv\components\catalog.json" -Algorithm SHA256).Hash
    $code4 = Invoke-Zpk @('sync', '--base', "$root\base") "$root\sync3.txt"
    $r3 = Get-Content "$root\sync3.txt" -Encoding UTF8 -Raw
    # ASCII markers only: PS 5.1 decodes native UTF-8 stdout as ANSI, so Chinese text in the
    # captured file is mojibake. '3600s' only appears in the "reuse cached catalog" line;
    # 'BadSignature' only appears when cache verification failed.
    $cached_ok = ($r3 -match '3600s') -and -not ($r3 -match 'BadSignature')

    # 8) mirror mode: catalog + packages must come from MirrorUrl, not from StoreUrl.
    #    StoreUrl points at a dead port on purpose - if the mirror were ignored the sync could not install.
    New-Item -ItemType Directory -Force "$root\base2\Config", "$root\base2\data" | Out-Null
    Set-Content "$root\base2\data\dbip-city-lite.mmdb" -Value 'placeholder' -Encoding ascii
    Set-Content "$root\base2\data\dbip-asn-lite.mmdb" -Value 'placeholder' -Encoding ascii
    $cfg_mirror = "StoreUrl = `"http://127.0.0.1:1`"`nMirrorUrl = `"http://127.0.0.1:$port`"`nPubKey = `"`"`nAutoEnroll = false`nDownloadV6 = false`nDataDir = `"data`"`nCacheDir = `"cache`"`nStateDir = `"client`"`nCatalogMaxAge = 0`nHttpTimeoutMs = 5000`n"
    [System.IO.File]::WriteAllText("$root\base2\Config\Ip.toml", $cfg_mirror, (New-Object System.Text.UTF8Encoding($false)))
    $code5 = Invoke-Zpk @('sync', '--base', "$root\base2") "$root\sync4.txt"
    $mirror_installed = Test-Path "$root\base2\cache\ip2region-v4\2026.11"

    # 9) mirror DOWN, platform up: sync must fall back to StoreUrl and still install.
    #    (mirror is a bandwidth optimisation, never a new failure mode)
    New-Item -ItemType Directory -Force "$root\base3\Config", "$root\base3\data" | Out-Null
    Set-Content "$root\base3\data\dbip-city-lite.mmdb" -Value 'placeholder' -Encoding ascii
    Set-Content "$root\base3\data\dbip-asn-lite.mmdb" -Value 'placeholder' -Encoding ascii
    $cfg_fallback = "StoreUrl = `"http://127.0.0.1:$port`"`nMirrorUrl = `"http://127.0.0.1:$port/absent`"`nPubKey = `"`"`nAutoEnroll = false`nDownloadV6 = false`nDataDir = `"data`"`nCacheDir = `"cache`"`nStateDir = `"client`"`nCatalogMaxAge = 0`nHttpTimeoutMs = 5000`n"
    [System.IO.File]::WriteAllText("$root\base3\Config\Ip.toml", $cfg_fallback, (New-Object System.Text.UTF8Encoding($false)))
    $code6 = Invoke-Zpk @('sync', '--base', "$root\base3") "$root\sync5.txt"
    $fallback_installed = Test-Path "$root\base3\cache\ip2region-v4\2026.11"
} finally {
    Stop-ServerOnPort $port
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
}

# 6) assertions
# exit codes are 1 here on purpose: the fake catalog only ships one dataset, so the
# other three report "missing component". That is unrelated to what we verify.
$fail = 0
function Assert([bool]$cond, [string]$name, [string]$detail) {
    if ($cond) {
        Write-Output ("PASS  {0}  {1}" -f $name, $detail)
    } else {
        Write-Output ("FAIL  {0}  {1}" -f $name, $detail)
        $script:fail++
    }
}

$r2 = Get-Content "$root\sync2.txt" -Encoding UTF8 -Raw
Assert $v10 'install-v1' '2026.10 installed by first sync'
Assert $v11 'upgrade-to-v2' '2026.11 installed by second sync'
Assert (-not $v10_after) 'clean-old-version' '2026.10 removed (keep = 1)'
Assert ([bool]($r2 -match '2026\.11')) 'detect-newer' 'second sync mentions 2026.11'
Assert ([bool]($lk -match 'Guangdong')) 'lookup-uses-new-data' 'lookup returns v2 region (Guangdong), not v1 (Jiangsu)'
Assert $cached_ok 'catalog-cache-reused' 'third sync reuses cached catalog (no refetch, no failed signature)'
Assert $mirror_installed 'mirror-mode' 'sync installs from MirrorUrl while StoreUrl is a dead port'
Assert $fallback_installed 'mirror-fallback' 'missing mirror falls back to StoreUrl and still installs'

Write-Output ("zpk exit codes (expected 1 for sync: fake catalog ships 1 of 4 datasets): {0}, {1}; lookup={2}; cached-sync={3}; mirror-sync={4}; fallback-sync={5}" -f $code1, $code2, $code3, $code4, $code5, $code6)
if ($fail -gt 0) {
    Write-Output "=== RESULT: FAIL ($fail) ==="
    exit 1
}
Write-Output "=== RESULT: PASS (fail=0) ==="
exit 0
