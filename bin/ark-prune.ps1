<#
.SYNOPSIS
  ark-prune.ps1 —— /srv/storage/ark/results 保留期清理工具（Windows 侧，北京时间，无时区后缀）。

.DESCRIPTION
  保留策略（已确认，方案 B，数字不可更改）：
    summary_final.*、rounds.csv、receipt、manifest.json 等摘要/证据文件 —— 永久保留
    */serial_logs/* 下的串口日志 —— 超过 30 天后删除
    */tool.log 工具日志 —— 超过 90 天后删除

  白名单（核心安全属性，任何参数组合下都不得突破）：
    只有同时满足以下两个路径模式之一的普通文件才可能成为候选：
      */serial_logs/*   任意层级的 serial_logs 目录下的文件
      */tool.log        任意层级、文件名恰为 tool.log 的文件
    白名单之外的任何文件永远不会被本脚本删除。目录遍历由本脚本自己维护栈，
    遇到符号链接/重解析点（reparse point）一律跳过、绝不向下钻取；候选必须
    落在 serial_logs 父目录之下或文件名恰为 tool.log，最后只对逐个列出的
    白名单文件调用 Remove-Item，绝不删除目录。

  默认是预演（dry-run）：只打印将被删除的文件、大小、契约格式的 mtime
  以及合计数量和可释放字节数，不删除任何东西。只有显式传 -Apply 才删除。

.PARAMETER Root
  必填，结果根目录（例如 Z:\ark\results 或映射到 linux003 的共享路径）。

.PARAMETER SerialDays
  serial_logs 保留天数，正整数，默认 30。

.PARAMETER ToolDays
  tool.log 保留天数，正整数，默认 90。

.PARAMETER Apply
  真正执行删除（默认只预演）。

.PARAMETER Yes
  跳过交互确认，仅配合 -Apply 使用。

.EXAMPLE
  .\ark-prune.ps1 -Root 'Z:\ark\results'
  .\ark-prune.ps1 -Root 'Z:\ark\results' -Apply
  .\ark-prune.ps1 -Root 'Z:\ark\results' -Apply -Yes

.NOTES
  退出码：
    0  成功（包括"没有可清理的文件"）
    1  确认提示处输入的不是 yes，已中止
    2  用法/参数错误：缺少或非法 -Root、天数不是正整数、在过宽的根目录上运行
    5  根目录不存在，或不是目录
#>
# 时间契约：本脚本展示的时间一律为北京时间（UTC+8），无时区后缀。
[CmdletBinding()]
param(
  [string]$Root = '',
  [string]$SerialDays = '30',
  [string]$ToolDays = '90',
  [switch]$Apply,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Stop-WithError {
  param([string]$Message, [int]$Code)
  [Console]::Error.WriteLine($Message)
  exit $Code
}

# ---------------------------------------------------------------- 北京时间契约
$LibPath = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'ark-time.ps1'
if (-not (Test-Path -LiteralPath $LibPath -PathType Leaf)) {
  Stop-WithError "缺少时间契约库: $LibPath" 2
}
. $LibPath

# ---------------------------------------------------------------- 工具函数
function Test-PositiveInt {
  param([string]$Text)
  if ($Text -notmatch '^\d+$') { return $false }
  $parsed = [int64]0
  if (-not [int64]::TryParse($Text, [ref]$parsed)) { return $false }
  return ($parsed -gt 0)
}

function Test-ReparsePoint {
  param($Item)
  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-NormalizedPath {
  param([string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  $full = $full -replace '\\', '/'
  if ($full.Length -gt 1) { $full = $full.TrimEnd('/') }
  return $full
}

function Get-CandidateFiles {
  # 自己维护目录栈，逐层枚举；遇到符号链接/重解析点直接跳过，避免逃出白名单。
  param([string]$StartDir)
  $found = New-Object System.Collections.Generic.List[object]
  $pending = New-Object System.Collections.Generic.Stack[string]
  $pending.Push($StartDir)
  while ($pending.Count -gt 0) {
    $dir = $pending.Pop()
    $entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
    foreach ($entry in $entries) {
      if (Test-ReparsePoint -Item $entry) { continue }
      if ($entry.PSIsContainer) {
        $pending.Push($entry.FullName)
        continue
      }
      $found.Add($entry)
    }
  }
  return $found
}

# ---------------------------------------------------------------- 参数校验
if ([string]::IsNullOrWhiteSpace($Root)) {
  Stop-WithError '错误：缺少必填参数 -Root' 2
  exit 2
}
if (-not (Test-PositiveInt -Text $SerialDays)) {
  Stop-WithError "错误：-SerialDays 必须是正整数，收到: $SerialDays" 2
  exit 2
}
if (-not (Test-PositiveInt -Text $ToolDays)) {
  Stop-WithError "错误：-ToolDays 必须是正整数，收到: $ToolDays" 2
  exit 2
}
$SerialDaysValue = [int64]$SerialDays
$ToolDaysValue = [int64]$ToolDays

$rootFull = Get-NormalizedPath -Path $Root
# 先做字面量判断：即使这些目录当前不存在也要明确拒绝，而不是落到 exit 5
if (@('/', '/srv', '/srv/storage', '/srv/storage/ark') -contains $rootFull) {
  Stop-WithError "错误：拒绝在过宽的根目录上运行: $rootFull（会波及其他数据），请指定具体结果目录" 2
  exit 2
}

if (-not (Test-Path -LiteralPath $Root)) {
  Stop-WithError "错误：根目录不存在: $Root" 5
  exit 5
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
  Stop-WithError "错误：根路径不是目录: $Root" 5
  exit 5
}

# 若根路径本身是符号链接/联接点，按真实目标再判一次，防止绕过过宽目录检查
$rootItem = Get-Item -LiteralPath $Root -Force
if (Test-ReparsePoint -Item $rootItem) {
  $target = @($rootItem.Target)
  if ($target.Count -gt 0 -and $target[0]) {
    $rootFull = Get-NormalizedPath -Path ([string]$target[0])
    if (@('/', '/srv', '/srv/storage', '/srv/storage/ark') -contains $rootFull) {
      Stop-WithError "错误：拒绝在过宽的根目录上运行: $rootFull（会波及其他数据），请指定具体结果目录" 2
      exit 2
    }
  }
}
$rootNative = $rootFull -replace '/', [System.IO.Path]::DirectorySeparatorChar

# ---------------------------------------------------------------- 收集候选
$serialCutoff = (Get-Date).AddDays(-1 * $SerialDaysValue)
$toolCutoff = (Get-Date).AddDays(-1 * $ToolDaysValue)

$allFiles = Get-CandidateFiles -StartDir $rootNative

# 显式 Where-Object：serial_logs 父目录链 或 文件名恰为 tool.log，二者以外一律不碰
$candidates = @($allFiles | Where-Object {
    $isSerial = (($_.DirectoryName -split '[\\/]') -contains 'serial_logs') -and ($_.LastWriteTime -lt $serialCutoff)
    $isTool = ($_.Name -eq 'tool.log') -and ($_.LastWriteTime -lt $toolCutoff)
    $isSerial -or $isTool
  } | Sort-Object -Property FullName)

$count = $candidates.Count
$bytes = [int64]0
foreach ($c in $candidates) { $bytes += [int64]$c.Length }
$mib = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', ($bytes / 1MB))

Write-Output "root      : $rootFull"
Write-Output "policy    : serial_logs > ${SerialDaysValue}d, tool.log > ${ToolDaysValue}d, everything else kept"
Write-Output "candidates: $count files, $bytes bytes ($mib MiB)"

# 无论是否 -Apply，先把每个候选的大小和契约格式 mtime 全部打印出来
if ($count -gt 0) {
  Write-Output '--- candidates ---'
  foreach ($c in $candidates) {
    # 所有展示时间都必须走 ConvertTo-ArkTime，禁止在此处内联格式化
    $mtime = ConvertTo-ArkTime -Value $c.LastWriteTime
    Write-Output ('{0,12}  {1}  {2}' -f $c.Length, $mtime, $c.FullName)
  }
}

if (-not $Apply) {
  Write-Output '[dry-run] nothing deleted; pass -Apply to delete'
  exit 0
}

if ($count -eq 0) {
  Write-Output 'nothing to prune'
  exit 0
}

if (-not $Yes) {
  $answer = Read-Host "delete $count files ($bytes bytes, $mib MiB)? [yes/N]"
  if ($answer -ne 'yes') {
    Write-Output 'aborted'
    exit 1
  }
}

# 只删除上面列表中逐个列出的白名单文件，绝不删除目录
$deleted = 0
foreach ($c in $candidates) {
  Remove-Item -LiteralPath $c.FullName -Force
  $deleted++
}
Write-Output "deleted $deleted files"
