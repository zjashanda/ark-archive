# ark-time.ps1 —— 北京时间无时区时间契约的 PowerShell 入口（Windows 5.1+）。
#
# 用法（dot-source 后调用）：
#   . .\lib\ark-time.ps1
#   Get-ArkTimeNow                 # 2026-11-10 12:09:56
#   Get-ArkTimeStamp               # 20261110_120956
#   ConvertTo-ArkTime $raw         # 把任意时间规范化为契约格式
#   Test-ArkTime '2026-11-10 12:09:56'   # $true/$false
#
# 约定：所有格式化都必须走这里，禁止脚本里自己写
# `Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'`（那是 UTC 且违反契约）。
# 规则与 lib/ark_time.py 完全一致：固定 UTC+8，无 T/Z/偏移。

$script:ArkContractFormat = 'yyyy-MM-dd HH:mm:ss'
$script:ArkStampFormat = 'yyyyMMdd_HHMMSS'
$script:ArkContractRegex = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'

function Get-ArkBeijingOffset {
    # Asia/Shanghai 固定 UTC+8（1991 年后无夏令时），不依赖系统时区数据库
    return [TimeSpan]::FromHours(8)
}

function ConvertTo-ArkDateTime {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [datetimeoffset]) {
        return $Value.ToOffset((Get-ArkBeijingOffset)).DateTime
    }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            # 朴素时间按北京时间处理——本项目所有数据源都是北京时间
            return $Value
        }
        return $Value.ToUniversalTime().Add((Get-ArkBeijingOffset))
    }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text -eq '') { throw '时间是空字符串' }
        if ($text -match $script:ArkContractRegex) {
            return [datetime]::ParseExact($text, $script:ArkContractFormat, $null)
        }
        $parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($text, [ref]$parsed)) {
            return $parsed.ToOffset((Get-ArkBeijingOffset)).DateTime
        }
        throw "无法识别的时间格式: $Value"
    }
    throw "不支持的时间类型: $($Value.GetType().FullName)"
}

function ConvertTo-ArkTime {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Value)
    return (ConvertTo-ArkDateTime -Value $Value).ToString($script:ArkContractFormat)
}

function ConvertTo-ArkStamp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)]$Value)
    if ($null -eq $Value) {
        return (Get-Date).ToUniversalTime().Add((Get-ArkBeijingOffset)).ToString($script:ArkStampFormat)
    }
    return (ConvertTo-ArkDateTime -Value $Value).ToString($script:ArkStampFormat)
}

function Get-ArkTimeNow {
    return (Get-Date).ToUniversalTime().Add((Get-ArkBeijingOffset)).ToString($script:ArkContractFormat)
}

function Get-ArkTimeStamp {
    return (Get-Date).ToUniversalTime().Add((Get-ArkBeijingOffset)).ToString($script:ArkStampFormat)
}

function Test-ArkTime {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch $script:ArkContractRegex) { return $false }
    if ($Value -match '[TZz]') { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact($Value, $script:ArkContractFormat, $null, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
}

function Get-ArkTimeAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Value -notmatch $script:ArkContractRegex) { $problems.Add('格式不是 YYYY-MM-DD HH:MM:SS') }
    if ($Value -match 'T') { $problems.Add("含 ISO 'T' 分隔符") }
    if ($Value -match '[Zz]$') { $problems.Add("含 UTC 'Z' 后缀") }
    if ($Value -match '[+-]\d{2}:?\d{2}$') { $problems.Add('含时区偏移') }
    if ($Value -match '(UTC|GMT)') { $problems.Add('含 UTC/GMT 字样') }
    return $problems
}
