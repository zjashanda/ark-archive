# 时间契约（北京时间，无时区）

本文件定义 `ark-archive` 全仓库唯一的时间格式规则。来源决策：NOAH-43。所有脚本、schema、测试、文档都必须遵守这一套规则。

## 规则

1. **所有用户可见的时间都是北京时间**（Asia/Shanghai，UTC+8）。
2. 文本格式固定为 `YYYY-MM-DD HH:MM:SS`。**禁止**出现 `T` 分隔符、`Z` 后缀、`+08:00` 之类的时区偏移，也禁止出现 `UTC` / `GMT` 字样。
3. 文件名中的时间戳固定为 `YYYYMMDD_HHMMSS`。
4. 原始来源时间（设备日志、`summary_final.json` 等）只能以 `raw` 前缀的字段保留，不得直接透传给用户。
5. 格式化只有一处实现：`lib/ark_time.py`。`lib/ark-time.sh` 与 `lib/ark-time.ps1` 只是薄封装。**任何 skill 或脚本都不得自己格式化时间。**

## 为什么这样定

- **单一实现**：过去每个 skill 各写各的 `strftime`，同一份数据在不同报告里长得不一样。现在格式化只走 `lib/ark_time.py`，改规则只改一处。
- **不依赖 tzdata**：固定使用 UTC+8 偏移，而不是查询时区数据库。Windows 精简环境、精简容器常常缺 tzdata，用固定偏移就不会因为环境不同而输出不同的时间。
- **固定偏移是精确的**：北京时间自 1991 年起不再实行夏令时，全年固定 UTC+8。对本项目覆盖的全部历史数据和未来数据，固定偏移与 `Asia/Shanghai` 完全等价。
- **去掉时区噪音**：归档场景的使用者都在同一时区，时间字符串里带 `Z` 或 `+08:00` 只会增加解析分歧，不会增加信息量。真正的时区信息在契约本身已经确定。

## 允许与禁止

| 场景 | 允许 | 禁止 |
|---|---|---|
| 用户可见时间 | `2026-11-10 12:09:56` | `2026-11-10T12:09:56+08:00`、`2026-11-10T04:09:56Z`、`2026-11-10 12:09:56 UTC` |
| 文件名时间戳 | `20261110_120956` | `2026-11-10T12:09:56Z` |
| 原始来源时间 | `raw_started_at: "2026-11-09T02:54:39Z"` | 把原始值直接写进 `started_at` |

> 上表“禁止”列里的写法只用于说明违规形态，任何脚本输出中都不允许出现。

## 正反例

### Python

```python
# 错误：自己拼 RFC3339，带 T 和 Z
def bad_now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# 正确：只调用共享实现
import sys
sys.path.insert(0, "lib")
import ark_time

def good_now():
    return ark_time.now_text()          # 2026-11-10 12:09:56

def good_normalize(raw):
    return ark_time.to_text(raw)        # 任意来源格式 -> 契约格式
```

### Bash

```bash
# 错误：脚本里自己格式化，而且用的是 UTC
bad_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# 正确：source 薄封装后调用
. "$(dirname "$0")/../lib/ark-time.sh"
good_now()  { ark_now; }        # 2026-11-10 12:09:56
good_stamp(){ ark_stamp; }      # 20261110_120956
good_norm() { ark_normalize "$1"; }
```

### PowerShell

```powershell
# 错误：自己格式化，还带 T 和 Z
function Get-BadNow {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# 正确：dot-source 薄封装后调用
. .\lib\ark-time.ps1
function Get-GoodNow   { Get-ArkTimeNow }        # 2026-11-10 12:09:56
function Get-GoodStamp { Get-ArkTimeStamp }      # 20261110_120956
function Get-GoodNorm  { param($v) ConvertTo-ArkTime $v }
```

## `raw_*` 溯源规则

来源系统给出的时间可能带 `Z`、带偏移、带毫秒。这些值不能直接进入用户可见字段，但也不能丢，因为排查问题需要原始证据。规则如下：

- 用户可见字段（`started_at`、`ended_at`、`archived_at`、回执中的时间）一律是契约格式。
- 原始值写进对应的 `raw_*` 字段，例如 `raw_started_at`、`raw_ended_at`，值保持来源原样，不做任何改写。
- `raw_*` 字段是**可选的**：没有原始来源时间时可以不写，不要为了凑字段编造一个。
- 下游只读用户可见字段。需要追溯时再查 `raw_*`，并自行知道那是来源格式。

manifest v1 中 `started_at` / `ended_at` 是契约格式，`raw_started_at` / `raw_ended_at` 只在来源时间确实存在且与规范化结果不同时出现。

## `--legacy-rfc3339`（弃用过渡）

`ark_receipt.py`（以及把未知参数透传给它的 `ark-receipt.sh`）支持一个**默认关闭**的开关 `--legacy-rfc3339`。显式开启时，回执中的时间会输出旧版 RFC3339 形态（带 `+08:00` 偏移），供尚未迁移的 `ark-kb` 消费者使用。

- 默认行为永远是契约格式，不带任何时区信息。
- 该开关只用于兼容旧消费者，**新代码不得依赖它**。
- 旧参数 `--tz-offset` 已废弃，传入会被忽略并打印一条警告。
- 迁移路径：先让旧消费者升级到能解析 `YYYY-MM-DD HH:MM:SS`，然后删掉 `--legacy-rfc3339`。该开关计划在下一个大版本移除。

## 如何审计一个值

不要靠肉眼判断，用共享实现自带的审计函数。

Python：

```bash
python3 lib/ark_time.py audit "2026-11-10 12:09:56"
# 输出 ok，退出码 0

python3 lib/ark_time.py audit "2026-11-10T12:09:56Z"
# 输出 "含 ISO 'T' 分隔符; 含 UTC 'Z' 后缀"，退出码 1
```

```python
import ark_time
problems = ark_time.audit(value)
if problems:
    raise SystemExit("; ".join(problems))
```

PowerShell：

```powershell
. .\lib\ark-time.ps1
Get-ArkTimeAudit '2026-11-10 12:09:56'          # 返回空集合，表示合规
Get-ArkTimeAudit '2026-11-10T12:09:56Z'         # 返回问题列表
```

Bash 侧可以直接用 `ark_check` 做布尔判断：

```bash
. lib/ark-time.sh
ark_check "2026-11-10 12:09:56" && echo compliant
```

审计覆盖的违规面：格式不符、含 `T`、含 `Z`、含时区偏移、含 `UTC` / `GMT` 字样、不是合法日期时间。任何一项命中都应当修正，而不是放行。
