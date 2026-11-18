param(
    [string]$OutFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\gb2312.bin')
)

# 生成 GBK（CP936，GB2312 超集）双字节 → Unicode 映射表，供 QQWry（纯真）数据解码使用。
# 布局：双重循环 hi = 0x81..0xFE，lo = 0x40..0xFE（跳过 0x7F），下标 = (hi-0x81)*191 + (lo-0x40)，
# 每项 2 字节小端；0 表示该码位不可映射。总计 126*191 = 24066 项 = 48132 字节。
# 与 C# `Encoding.GetEncoding("GB2312")`（DH.NIP 用的就是它）保持同一张码表。

$ErrorActionPreference = 'Stop'

# PS 5.1 / .NET Framework 自带 CP936，无需注册 CodePagesEncodingProvider（那是 .NET Core 才需要）
$enc = [System.Text.Encoding]::GetEncoding(936)
$hiCount = 0xFE - 0x81 + 1
$loCount = 0xFE - 0x40 + 1
$entries = New-Object 'UInt16[]' ($hiCount * $loCount)

$pair = New-Object byte[] 2
$mapped = 0
for ($hi = 0x81; $hi -le 0xFE; $hi++) {
    for ($lo = 0x40; $lo -le 0xFE; $lo++) {
        if ($lo -eq 0x7F) { continue }
        $idx = ($hi - 0x81) * $loCount + ($lo - 0x40)
        $pair[0] = [byte]$hi
        $pair[1] = [byte]$lo
        $text = $enc.GetString($pair)
        if ($text.Length -ne 1) { continue }
        $cp = [int][char]$text[0]
        if ($cp -eq 0xFFFD) { continue }
        # 回写校验：必须能原样编回同一对字节，排除不可映射/替换字符
        $back = $enc.GetBytes($text)
        if ($back.Length -ne 2 -or $back[0] -ne $pair[0] -or $back[1] -ne $pair[1]) { continue }
        $entries[$idx] = [uint16]$cp
        $mapped++
    }
}

$bytes = New-Object byte[] ($entries.Length * 2)
[System.Buffer]::BlockCopy($entries, 0, $bytes, 0, $bytes.Length)
[System.IO.File]::WriteAllBytes($OutFile, $bytes)

Write-Output ("GBK 表已生成：{0}（{1} 项，可映射 {2}，{3} 字节）" -f $OutFile, $entries.Length, $mapped, $bytes.Length)
