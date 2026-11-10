<#
.SYNOPSIS
  bin/ark-archive.ps1 —— 把一个运行结果目录归档到 ark 存储服务器（linux003）。

.DESCRIPTION
  作用
    复制（从不移动）源目录到 <results-root>/<project>/<run_id>/，生成
    manifest.json（run_id / project / device / node / result / started_at /
    ended_at / files[path,bytes,sha256] / archived_at / source_dir），随后把
    共用的 lib/remote-verify.sh 上传到远端逐文件重算 sha256 校验。校验失败
    整体移入隔离区，绝不污染正式目录。

  暂存目录统一为 <results-root>/<node>/<project>/.incoming-<run_id>-<stamp>/，与 bash 入口
  完全一致，因此同一棵源树在两个入口下生成相同的 files[].path。

  用法
    $env:ARK_STORAGE_SSH_PASS = '<口令>'
    .\ark-archive.ps1 -SourceDir <目录> -Project <项目> `
        [-RunId <id>] [-Node <节点>] [-Device <设备>] [-Result <PASS|FAIL|...>] `
        [-StorageHost <主机>] [-StoragePort <端口>] [-StorageUser <用户>] `
        [-ResultsRoot <目录>] [-QuarantineRoot <目录>] [-SshPassEnv <变量名>] `
        [-LegacyRfc3339] [-DryRun]

  口令只从 -SshPassEnv（默认 ARK_STORAGE_SSH_PASS）指向的环境变量读取，
  脚本内不打印、不落盘明文。

  退出码
    0  成功（远端校验通过并已落盘）
    2  用法 / 校验错误（缺参数、路径非法、缺口令环境变量、构建 manifest 失败）
    3  远端哈希校验不一致（暂存目录已隔离）
    4  传输失败（ssh / scp 失败，或远端 move 失败）
    5  缺少依赖（ssh / scp）

  时间说明（NOAH-43）：manifest 中所有用户可见时间（started_at / ended_at /
  archived_at）一律为北京时间、格式 YYYY-MM-DD HH:MM:SS，无 T、无 Z、无时区
  偏移；全部格式化都走 lib/ark-time.ps1，脚本本身不调用 Get-Date 自行拼接
  时间。-LegacyRfc3339 为已废弃的旧消费者兼容开关，只影响 archived_at。

.PARAMETER DryRun
  只构建并打印 manifest 与计划执行的远端命令，不建立任何 ssh/scp 连接。

.EXAMPLE
  $env:ARK_STORAGE_SSH_PASS = '<口令>'
  .\ark-archive.ps1 -SourceDir D:\zhsh\workspace\tcl-r5\result\20261102_090644 -Project tcl-r5 -Device TCL-R5 -DryRun

.EXAMPLE
  .\ark-archive.ps1 -SourceDir D:\zhsh\workspace\tcl-r5\result\20261102_090644 -Project tcl-r5 -Device TCL-R5
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$Project,
  [string]$RunId = '',
  [string]$Node = '',
  [string]$Device = '',
  [string]$Result = '',
  [string]$StorageHost = '10.210.8.205',
  [int]$StoragePort = 22,
  [string]$StorageUser = 'administrator',
  [string]$ResultsRoot = '/srv/storage/ark/results',
  [string]$QuarantineRoot = '/srv/storage/ark/_quarantine',
  [string]$SshPassEnv = 'ARK_STORAGE_SSH_PASS',
  [switch]$DryRun,
  [switch]$Force,
  [switch]$LegacyRfc3339
)

$ErrorActionPreference = 'Stop'

function Fail-Code {
  param([int]$Code, [string]$Message)
  [Console]::Error.WriteLine($Message)
  exit $Code
}

# 定位仓库根目录，复用共用的时间契约与远端校验器（不复制、不修改）
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib/ark-time.ps1')
$VerifySource = Join-Path $RepoRoot 'lib/remote-verify.sh'

function ConvertTo-ArkLegacyTime {
  # 仅供 -LegacyRfc3339（已废弃）使用：给旧 ark-kb 消费者输出 +08:00 的 RFC3339。
  # 时刻本身仍由 lib 的 ConvertTo-ArkDateTime 规范化，这里只拼接契约允许的偏移。
  param([Parameter(Mandatory = $true)][string]$Value)
  $moment = ConvertTo-ArkDateTime -Value $Value
  $offset = Get-ArkBeijingOffset
  $totalMinutes = [int]$offset.TotalMinutes
  $sign = '+'
  if ($totalMinutes -lt 0) { $sign = '-' }
  $absMinutes = [Math]::Abs($totalMinutes)
  $hours = [int][Math]::Floor($absMinutes / 60)
  $minutes = [int]($absMinutes % 60)
  return $moment.ToString("yyyy-MM-dd'T'HH:mm:ss") + ('{0}{1:D2}:{2:D2}' -f $sign, $hours, $minutes)
}

function Get-ArkArchiveStamp {
  # 从 lib 产出的契约时间派生文件名时间戳 YYYYMMDD_HHMMSS。
  # 说明：lib/ark-time.ps1 的 Get-ArkTimeStamp 当前格式常量写作 'HHMMSS'，
  # .NET 会把大写的 SS 当字面量，输出 "..._HHMMSS" 而非秒数；该文件本轮不允许
  # 修改，因此这里只对 Get-ArkTimeNow 的结果做字符串切分，不自行读取系统时间。
  $text = Get-ArkTimeNow
  return $text.Substring(0, 4) + $text.Substring(5, 2) + $text.Substring(8, 2) + '_' +
    $text.Substring(11, 2) + $text.Substring(14, 2) + $text.Substring(17, 2)
}

function New-Sha256Table {
  param([System.IO.FileInfo[]]$Files, [string]$Root)
  $table = @{}
  foreach ($f in $Files) {
    $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
    $table[$rel] = [ordered]@{
      path   = $rel
      bytes  = $f.Length
      sha256 = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
    }
  }
  return $table
}

function Get-RunResult {
  param($Summary)
  if ($null -eq $Summary) { return '' }
  $rate = $null
  if ($Summary.PSObject.Properties.Name -contains 'normal_window' -and $Summary.normal_window) {
    if ($Summary.normal_window.PSObject.Properties.Name -contains 'recognition_rate') {
      $rate = [double]$Summary.normal_window.recognition_rate
    }
  }
  if ($null -eq $rate -and ($Summary.PSObject.Properties.Name -contains 'recognition_rate')) {
    $rate = [double]$Summary.recognition_rate
  }
  if ($null -ne $rate) { if ($rate -ge 0.9) { return 'PASS' } else { return 'FAIL' } }
  if ($Summary.PSObject.Properties.Name -contains 'status_counts' -and $Summary.status_counts) {
    return (($Summary.status_counts.PSObject.Properties | ForEach-Object { $_.Name }) -join '+')
  }
  return ''
}

function Get-SshOptions {
  param([string]$Port, [string]$KnownHosts)
  return @(
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', "UserKnownHostsFile=$KnownHosts",
    '-o', 'ConnectTimeout=10',
    '-o', 'LogLevel=ERROR',
    '-P', $Port
  )
}

# ---------------------------------------------------------------- 参数校验
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
  Fail-Code 2 "源目录不存在: $SourceDir"
}
$src = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
if (-not $RunId) { $RunId = Split-Path -Path $src -Leaf }
if (-not $RunId) { Fail-Code 2 '无法推导 RunId，请显式传入 -RunId' }
if (-not $Node) {
  if ($env:COMPUTERNAME) { $Node = $env:COMPUTERNAME.ToLower() } else { $Node = 'unknown' }
}
if ($Node -notmatch '^[a-z0-9._-]+$') { Fail-Code 2 "非法节点名: $Node" }
if ($Project -notmatch '^[A-Za-z0-9._-]+$') { Fail-Code 2 "非法项目名: $Project" }
if ($RunId -notmatch '^[A-Za-z0-9._-]+$') { Fail-Code 2 "非法运行 ID: $RunId" }
if (-not (Test-Path -LiteralPath $VerifySource -PathType Leaf)) {
  Fail-Code 2 "缺少远端校验器: $VerifySource"
}

# 枚举文件：跳过符号链接 / 重解析点，保留迁移前的行为
$files = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force |
  Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
if ($files.Count -eq 0) { Fail-Code 2 "源目录下没有任何文件: $src" }

$summaryPath = Join-Path $src 'summary_final.json'
# 原始 JSON 文本：ConvertFrom-Json 会把 ISO 时间自动转成 DateTime，导致原始字符串
# 丢失、且按本机时区重新解释。这里保留原文，用定向正则取出未经改动的来源字符串。
$summaryRaw = ''
$summary = $null
if (Test-Path -LiteralPath $summaryPath) {
  try {
    $summaryRaw = Get-Content -LiteralPath $summaryPath -Raw
    if ($summaryRaw) { $summary = $summaryRaw | ConvertFrom-Json }
  }
  catch {
    $summary = $null
  }
}

function Get-SummaryTimeText {
  param([string]$Json, [string]$Name)
  if (-not $Json) { return '' }
  $m = [regex]::Match($Json, '"' + [regex]::Escape($Name) + '"\s*:\s*"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

# ---------------------------------------------------------------- 时间契约
# 所有格式化都走 lib/ark-time.ps1；原始来源字符串保留到 raw_* 字段。
$startedAt = ''
$rawStarted = Get-SummaryTimeText -Json $summaryRaw -Name 'started_at'
if ($rawStarted.Trim()) {
  try { $startedAt = ConvertTo-ArkTime -Value $rawStarted } catch { $startedAt = '' }
}
if (-not $startedAt) {
  $earliest = ($files | Sort-Object LastWriteTime | Select-Object -First 1)
  $rawStarted = $earliest.LastWriteTime.ToString('o')
  $startedAt = ConvertTo-ArkTime -Value $earliest.LastWriteTime
}

$endedAt = ''
$rawEnded = Get-SummaryTimeText -Json $summaryRaw -Name 'ended_at'
if ($rawEnded.Trim()) {
  try { $endedAt = ConvertTo-ArkTime -Value $rawEnded } catch { $endedAt = '' }
}
if (-not $endedAt) {
  $latest = ($files | Sort-Object LastWriteTime | Select-Object -Last 1)
  $rawEnded = $latest.LastWriteTime.ToString('o')
  $endedAt = ConvertTo-ArkTime -Value $latest.LastWriteTime
}

if (-not $Result) { $Result = Get-RunResult -Summary $summary }
if (-not $Result) { $Result = 'unknown' }
if (-not $Device) {
  if ($env:COMPUTERNAME) { $Device = $env:COMPUTERNAME } else { $Device = $Node }
}

$table = New-Sha256Table -Files $files -Root $src
$fileKeys = [string[]]@($table.Keys)
[Array]::Sort($fileKeys, [System.StringComparer]::Ordinal)
$fileList = @($fileKeys | ForEach-Object { $table[$_] })
$totalBytes = 0
foreach ($f in $fileList) { $totalBytes += [int64]$f.bytes }

$archivedAt = Get-ArkTimeNow
if ($LegacyRfc3339) { $archivedAt = ConvertTo-ArkLegacyTime -Value $archivedAt }

$manifest = [ordered]@{
  schema      = 'manifest.v1'
  run_id      = $RunId
  project     = $Project
  device      = $Device
  node        = $Node
  result      = $Result
  started_at  = $startedAt
  ended_at    = $endedAt
  files       = $fileList
  archived_at = $archivedAt
  source_dir  = $src
}
if ($rawStarted) { $manifest['raw_started_at'] = $rawStarted }
if ($rawEnded) { $manifest['raw_ended_at'] = $rawEnded }

$manifestJson = $manifest | ConvertTo-Json -Depth 6
$targetDir = "$ResultsRoot/$Node/$Project/$RunId"
$stamp = Get-ArkArchiveStamp
$stageRoot = "$ResultsRoot/$Node/$Project/.incoming-$RunId-$stamp"
$remoteVerify = "$ResultsRoot/.verify-$RunId-$stamp.sh"
$remote = "$StorageUser@$StorageHost"

Write-Output "源目录      : $src"
Write-Output "目标目录    : $targetDir"
Write-Output "运行 ID     : $RunId"
Write-Output "项目        : $Project"
Write-Output "节点 / 设备 : $Node / $Device"
Write-Output "结果        : $Result"
Write-Output "时间区间    : $startedAt -> $endedAt"
Write-Output "文件 / 字节 : $($fileList.Count) ($totalBytes bytes)"

if ($DryRun) {
  Write-Output '--- 文件清单 ---'
  foreach ($f in $fileList) { Write-Output ("  {0,-45} {1,12} {2}" -f $f.path, $f.bytes, $f.sha256) }
  Write-Output '--- manifest.json（预览）---'
  Write-Output $manifestJson
  Write-Output '--- 计划执行的远端命令（-DryRun，不执行）---'
  Write-Output "  # 认证：一次性 askpass 脚本；口令只来自环境变量 $SshPassEnv"
  Write-Output "  ssh -n -p $StoragePort $remote `"mkdir -p '$stageRoot' && rm -f '$remoteVerify'`""
  $topItems = @(Get-ChildItem -LiteralPath $src -Force)
  foreach ($item in $topItems) {
    Write-Output ("  scp -P {0} -r `"{1}`" `"{2}:{3}/`"" -f $StoragePort, $item.FullName, $remote, $stageRoot)
  }
  Write-Output ("  scp -P {0} `"<manifest.json>`" `"{1}:{2}/manifest.json`"" -f $StoragePort, $remote, $stageRoot)
  Write-Output ("  scp -P {0} `"{1}`" `"{2}:{3}`"" -f $StoragePort, $VerifySource, $remote, $remoteVerify)
  Write-Output ("  ssh -n -p {0} {1} `"bash '{2}' '{3}' '{4}' '{5}' '{6}' '{7}'; rc=`$?; rm -f '{8}'; exit `$rc`"" -f $StoragePort, $remote, $remoteVerify, $stageRoot, $targetDir, $QuarantineRoot, $RunId, $stamp, $remoteVerify)
  Write-Output '[-DryRun] 未复制任何文件，未建立任何连接'
  exit 0
}

# ---------------------------------------------------------------- 依赖与认证
foreach ($tool in @('ssh', 'scp')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail-Code 5 "缺少依赖: $tool" }
}

$pass = [Environment]::GetEnvironmentVariable($SshPassEnv)
if (-not $pass) { Fail-Code 2 "缺少 SSH 口令：请先设置环境变量 $SshPassEnv" }

$work = Join-Path $env:TEMP "ark-archive-$RunId-$stamp"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$manifestFile = Join-Path $work 'manifest.json'
[System.IO.File]::WriteAllText($manifestFile, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
$askpass = Join-Path $work 'askpass.cmd'
Set-Content -LiteralPath $askpass -Value "@echo off`r`necho %__ARK_ASKPASS_VALUE%" -Encoding ASCII
$knownHosts = Join-Path $env:USERPROFILE '.ssh\ark_known_hosts'

$oldAskpass = $env:SSH_ASKPASS
$oldRequire = $env:SSH_ASKPASS_REQUIRE
$oldDisplay = $env:DISPLAY
$oldValue = $env:__ARK_ASKPASS_VALUE
try {
  $env:__ARK_ASKPASS_VALUE = $pass
  $env:SSH_ASKPASS = $askpass
  $env:SSH_ASKPASS_REQUIRE = 'force'
  $env:DISPLAY = 'localhost:0'

  $sshBase = @('-n', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$knownHosts",
    '-o', 'ConnectTimeout=10', '-o', 'LogLevel=ERROR')

  Write-Output '[1/5] mkdir remote staging'
  & ssh @sshBase -p $StoragePort $remote "mkdir -p '$stageRoot' && rm -f '$remoteVerify'" 2>&1 | ForEach-Object { Write-Output "  $_" }
  if ($LASTEXITCODE -ne 0) { Fail-Code 4 '远端创建暂存目录失败' }

  $scpOpts = Get-SshOptions -Port $StoragePort -KnownHosts $knownHosts

  # 逐项上传源目录的顶层条目，使其落在暂存目录根部（与 bash 的 rsync "$src/" 一致）
  Write-Output "[2/5] upload $($fileList.Count) files"
  $topItems = @(Get-ChildItem -LiteralPath $src -Force)
  foreach ($item in $topItems) {
    & scp @scpOpts -r $item.FullName "${remote}:$stageRoot/" 2>&1 | ForEach-Object { Write-Output "  $_" }
    if ($LASTEXITCODE -ne 0) { Fail-Code 4 "上传失败: $($item.Name)" }
  }

  Write-Output '[3/5] upload manifest + verifier'
  & scp @scpOpts $manifestFile "${remote}:$stageRoot/manifest.json" 2>&1 | ForEach-Object { Write-Output "  $_" }
  if ($LASTEXITCODE -ne 0) { Fail-Code 4 'manifest 上传失败' }
  & scp @scpOpts $VerifySource "${remote}:$remoteVerify" 2>&1 | ForEach-Object { Write-Output "  $_" }
  if ($LASTEXITCODE -ne 0) { Fail-Code 4 '校验器上传失败' }

  Write-Output '[4/5] remote sha256 verification'
  & ssh @sshBase -p $StoragePort $remote "bash '$remoteVerify' '$stageRoot' '$targetDir' '$QuarantineRoot/$Node' '$RunId' '$stamp'; rc=`$?; rm -f '$remoteVerify'; exit `$rc"
  $rc = $LASTEXITCODE
  Write-Output "[5/5] exit=$rc"
  if ($rc -eq 0) {
    Write-Output 'ARCHIVE_OK'
  }
  elseif ($rc -eq 2 -or $rc -eq 3) {
    Fail-Code 3 "远端哈希校验不一致（rc=$rc），暂存目录已隔离"
  }
  else {
    Fail-Code 4 "归档失败（远端 rc=$rc）"
  }
}
finally {
  $env:SSH_ASKPASS = $oldAskpass
  $env:SSH_ASKPASS_REQUIRE = $oldRequire
  $env:DISPLAY = $oldDisplay
  $env:__ARK_ASKPASS_VALUE = $oldValue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
