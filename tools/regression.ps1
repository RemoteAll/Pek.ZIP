# Pek.ZIP 一键回归入口：构建 → 单元测试（含真实数据）→ CLI 自检 → 可选真实数据自检。
# 退出码 0/1，可直接接 CI。报告落 artifacts\regression\report-<时间戳>.txt。
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1 -PekIpData 'G:\Code\Rust\Pek.IP\data'
#
# 说明：
# - 单测下限写在 $MinTests（新增用例必须抬高；降低必须写进 docs\决策记录.md）。
# - 真实数据只读引用，不复制 60 MB 数据文件；缺失时显式 SKIP 并说明原因（不静默通过）。

param(
    [string]$PekIpData = 'G:\Code\Rust\Pek.IP\data',
    [int]$MinTests = 60
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$reportDir = Join-Path $root 'artifacts\regression'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = Join-Path $reportDir "report-$stamp.txt"

$script:failures = 0
$script:skips = 0

function Log([string]$text) {
    Write-Host $text
    Add-Content -Path $report -Value $text -Encoding UTF8
}

# PS 5.1：外部程序写 stderr 在 $ErrorActionPreference='Stop' 下会被当成终止错误 → 临时 Continue 并取退出码。
function Invoke-Native([scriptblock]$block) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $block 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return @{ Output = $output; Code = $code }
}

function Assert([bool]$condition, [string]$name, [string]$detail) {
    if ($condition) {
        Log ("PASS  {0}  {1}" -f $name, $detail)
    } else {
        $script:failures++
        Log ("FAIL  {0}  {1}" -f $name, $detail)
    }
}

function Skip([string]$name, [string]$reason) {
    $script:skips++
    Log ("SKIP  {0}  {1}" -f $name, $reason)
}

Push-Location $root
# zpk / zig 输出 UTF-8；PS 5.1 默认按 ANSI 解码 → 中文断言会假失败
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

try {
    Log ("=== Pek.ZIP regression {0} ===" -f $stamp)

    # 1) 单元测试（xdb / mmdb / qqwry / 合并 / 目录 / 安装 / 管理器）
    # 注意：`zig build test` 命中缓存时不会再打印用例数，所以直接跑 `zig test` 取可靠计数。
    $result = Invoke-Native { zig test src/root.zig }
    Log $result.Output
    $passMatch = [regex]::Match($result.Output, 'All\s+(\d+)\s+tests passed')
    $failMatch = [regex]::Match($result.Output, '(\d+)\s+failed')
    $passCount = if ($passMatch.Success) { [int]$passMatch.Groups[1].Value } else { 0 }
    $failCount = if ($failMatch.Success) { [int]$failMatch.Groups[1].Value } else { 0 }

    Assert ($result.Code -eq 0) 'unit-tests-exit' ("exit={0}" -f $result.Code)
    Assert ($failCount -eq 0) 'unit-tests-failures' ("fail={0}" -f $failCount)
    Assert ($passCount -ge $MinTests) 'unit-tests-baseline' ("pass={0} (>= {1})" -f $passCount, $MinTests)
    if ($result.Output -match '\[SKIP\]') { Skip 'real-data-in-unit-tests' '部分真实数据用例按设计跳过（输出中已标注 [SKIP] 与原因）' }

    # 2) CLI 构建
    $result = Invoke-Native { zig build }
    Assert ($result.Code -eq 0) 'zig-build' ("exit={0}" -f $result.Code)

    $zpk = Join-Path $root 'zig-out\bin\zpk.exe'
    if (-not (Test-Path $zpk)) {
        Assert $false 'zpk-binary' '缺少 zig-out\bin\zpk.exe'
    } else {
        # 3) 合成数据自检（确定性；验证 CLI 与 xdb 读取链路）
        $base = Join-Path $root '.zig-cache\regression-base'
        Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force (Join-Path $base 'data') | Out-Null

        $result = Invoke-Native { & $zpk mkxdb (Join-Path $base 'data\ip2region_v4.xdb') }
        Assert ($result.Code -eq 0) 'mkxdb' ("exit={0}" -f $result.Code)

        $result = Invoke-Native { & $zpk selfcheck --base $base }
        $selfcheck = $result.Output
        Assert ($result.Code -eq 0) 'selfcheck-exit' ("exit={0}" -f $result.Code)
        Assert ($selfcheck -match '测试省') 'selfcheck-synthetic-cn' '合成 xdb 的国内记录可查'
        Assert ($selfcheck -match '澳大利亚') 'selfcheck-synthetic-au' '合成 xdb 的国外记录可查'
        Assert ($selfcheck -match '局域网') 'selfcheck-reserved' '内网地址短路生效'

        # 4) 真实数据（可选）：DataDir 指向 Pek.IP 的 data/，只读复用
        $realV4 = Join-Path $PekIpData 'ip2region_v4.xdb'
        if (Test-Path $realV4) {
            $realBase = Join-Path $root '.zig-cache\regression-real'
            Remove-Item -Recurse -Force $realBase -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force (Join-Path $realBase 'Config') | Out-Null
            $toml = @"
StoreUrl = ""
DataDir = "$($PekIpData -replace '\\','/')"
CacheDir = "$((Join-Path $realBase 'cache') -replace '\\','/')"
"@
            Set-Content -Path (Join-Path $realBase 'Config\Ip.toml') -Value $toml -Encoding UTF8

            $result = Invoke-Native { & $zpk selfcheck --base $realBase }
            $real = $result.Output
            Assert ($result.Code -eq 0) 'real-selfcheck-exit' ("exit={0}" -f $result.Code)
            Assert ($real -match '江苏省') 'real-ip2region' '114.114.114.114 → 江苏省（真实 xdb）'
            Assert ($real -match '美国') 'real-mmdb' '8.8.8.8 → 美国（真实 MMDB）'
        } else {
            Skip 'real-data-selfcheck' ("未找到 {0}（放好 Pek.IP 的 data/ 后自动启用）" -f $realV4)
        }

        # 5) 基准（短跑，仅验证 ReleaseFast 基准可运行；不作性能门槛）
        $result = Invoke-Native { zig build bench -- $PekIpData 20000 }
        if ($result.Output -match 'xdb \(ip2region v4\)') {
            Assert ($result.Code -eq 0) 'bench-smoke' '基准可运行（ReleaseFast）'
        } else {
            Skip 'bench-smoke' '缺少真实数据，基准未运行'
        }
    }

    Log ("=== 结果：失败 {0}，跳过 {1} ===" -f $script:failures, $script:skips)
    Log ("report: {0}" -f $report)
    if ($script:failures -gt 0) { exit 1 } else { exit 0 }
} finally {
    [Console]::OutputEncoding = $previousEncoding
    Pop-Location
}
