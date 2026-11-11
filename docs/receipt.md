# 归档回执 receipt.v1

回执（receipt）是**一次压测/归档运行的机器可读结论**：`bin/ark_receipt.py` 读取归档目录里的
`manifest.json`（以及可选的 `summary_final.json`），生成一份 `run.receipt.json`。它是
ark-kb 建条目、看板统计、追责归因的唯一输入，所以字段形状与时间格式都必须稳定。

- schema 文件：[`schemas/receipt.v1.json`](../schemas/receipt.v1.json)（JSON Schema draft-07）
- 生成器：[`bin/ark_receipt.py`](../bin/ark_receipt.py)
- 包装器：[`bin/ark-receipt.sh`](../bin/ark-receipt.sh)（Linux/macOS/Git Bash）、
  [`bin/ark-receipt.ps1`](../bin/ark-receipt.ps1)（Windows PowerShell 5.1）
- 时间契约唯一实现：[`lib/ark_time.py`](../lib/ark_time.py)

回执本身**只做本地只读计算**：不联网、不传文件。取/传（scp、ssh、远端 sha256 复算）由两个
包装器负责。

## 1. 时间契约（NOAH-43）

所有**用户可见**的时间一律是**北京时间、无时区后缀**，格式固定为
`YYYY-MM-DD HH:MM:SS`：

```text
2026-11-10 12:31:00
```

没有 `T`、没有 `Z`、没有 `+08:00`。涉及字段：

| 字段 | 说明 |
|---|---|
| `started_at` | 运行开始时间 |
| `ended_at` | 运行结束时间 |
| `archive.archived_at` | 归档时间 |
| `notes` | 文本中引用的归档时间也必须是契约格式，绝不透传原始 `Z` / 偏移 |

格式化只有一条路径：`ark_time.to_text(...)`。`ark_receipt.py` 内部**没有**自己的时间
拼接函数。输入侧可以宽松（带 `T`、带 `Z`、带偏移、纯 epoch 都能解析），输出侧严格。

原始来源时间（设备日志、`summary_final.json` 原值等）不进入回执：溯源信息保留在
`manifest.v1` 的 `raw_started_at` / `raw_ended_at` 字段里（见
[`schemas/manifest.v1.json`](../schemas/manifest.v1.json)）。回执只承载规范化后的北京时间，
这样 `run.receipt.v1` 的任何时间字段都不会出现 `T` / `Z` / 偏移。

`--tz-offset` 已废弃：仍然接受，但不产生任何效果，只在 stderr 打一行
`WARN: --tz-offset 已废弃…`。

### `--legacy-rfc3339`（默认关闭）

给尚未迁移的旧 ark-kb 消费者用。开启后，上面三个字段改由
`ark_time.legacy_rfc3339()` 输出旧形状：

```text
2026-11-10T12:31:00+08:00
```

除此之外字段完全不变。注意：**legacy 回执有意不满足 `receipt.v1.json` 的时间正则**
（正则要求空格分隔、无偏移），这是兼容期的一次性例外，新代码不得默认开启。

## 2. 字段表

类型里 `|null` 表示允许 JSON null。带「必填」的字段由 schema 的 `required` 强制。

| 字段 | 类型 | 必填 | 说明 / 北京时间示例 |
|---|---|---|---|
| `schema` | string，const `run.receipt.v1` | 是 | 固定值，用于版本分派 |
| `run_id` | string | 是 | 运行标识，通常是 `YYYYMMDD-HHMMSS_slug`（历史归档可能为下划线形式） |
| `task` | string | 是 | 任务描述，进 KB 标题/claim |
| `skill` | string | 是 | 产出该结果的 skill，默认 `lstest` |
| `skill_version` | string | 是 | skill 版本，未知时 `unknown` |
| `scope.device` | string \| null | 是 | 设备型号，取自 `manifest.device` |
| `scope.project` | string | 是 | 项目名 |
| `scope.firmware` | string \| null | 是 | 固件标识（`--firmware`） |
| `scope.platform` | string | 是 | 平台描述，默认 `<node> (<device>)` |
| `result` | enum | 是 | `pass` / `fail` / `blocked` / `invalid` / `needs_review` |
| `totals.rounds` | integer ≥0 | 是 | 已完成轮数（`completed_rounds`） |
| `totals.target_rounds` | integer ≥0 | 是 | 目标轮数 |
| `totals.duration_minutes` | number ≥0 | 是 | 运行时长（分钟） |
| `totals.recognized` | integer ≥0 | 是 | 正常窗口识别成功数 |
| `totals.failed` | integer ≥0 | 是 | 正常窗口未识别数 |
| `totals.recognition_rate` | number 0..1 \| null | 是 | 识别率；summary 未提供时为 null |
| `totals.boundary_unexpected` | integer ≥0 | 是 | 边界窗口非预期结果数 |
| `totals.serial_error_kinds` | integer ≥0 | 是 | 串口错误**种类数**（`serial_errors` 的键数） |
| `totals.warning_markers` | integer ≥0 | 是 | 告警标记**总次数**（各轮计数求和） |
| `totals.archived_files` | integer ≥0 | 是 | 归档文件数（= `evidence_files` 长度） |
| `totals.archived_bytes` | integer ≥0 | 是 | 归档总字节 |
| `totals.status_counts` | object\<string,int\> | 否 | summary 提供时原样带出，否则整段省略 |
| `failures[].name` | string | 是 | 失败项名称 |
| `failures[].reason` | string | 是 | 失败原因（≤500 字） |
| `failures[].attribution` | string | 是 | 归因：`device` / `corpus` / `tool` 等 |
| `failures[].evidence` | string[] | 是 | 证据文件名 |
| `bugs_found` | object[] | 是 | 来自 `--bugs` 的 JSON 数组，默认 `[]` |
| `evidence_dir` | string | 是 | 证据**存储**目录，不是跑测机临时目录 |
| `evidence_sha256` | string[]，`^[0-9a-f]{64}$` | 是 | 与 `manifest.files` 同序的哈希数组 |
| `evidence_files[].path` | string | 是 | 相对路径，正斜杠 |
| `evidence_files[].sha256` | string，`^[0-9a-f]{64}$` | 是 | 文件哈希（小写） |
| `evidence_files[].bytes` | integer ≥0 | 是 | 文件字节数 |
| `lessons` | array | 是 | 来自 `--lessons` 的 JSON 数组，默认 `[]` |
| `confidence` | enum `high`/`medium`/`low` | 是 | 见下方派生规则 |
| `started_at` | string，`YYYY-MM-DD HH:MM:SS` | 是 | 例 `2026-11-10 12:00:00` |
| `ended_at` | string，`YYYY-MM-DD HH:MM:SS` | 是 | 例 `2026-11-10 12:30:05` |
| `notes` | string | 是 | 生成说明（节点/项目/归档时间/文件数/源目录） |
| `tags` | string[]，唯一 | 是 | `archive` + 节点 + 项目 + 结果 + `--tags` |
| `archive.node` | string | 是 | 归档节点名 |
| `archive.project` | string | 是 | 归档项目名 |
| `archive.storage_root` | string | 是 | 存储根，默认 `/srv/storage/ark` |
| `archive.archived_at` | string，`YYYY-MM-DD HH:MM:SS` | 是 | 例 `2026-11-10 12:31:00` |
| `archive.source_dir` | string \| null | 是 | 跑测机上的原始结果目录 |
| `archive.manifest_sha256` | string，`^[0-9a-f]{64}$` | 是 | 所用 `manifest.json` 的哈希 |

`evidence_sha256` 与 `evidence_files` 是同一批文件的两种视图：前者给只想要哈希的消费方，
后者给「证据不在本机也要登记路径」的 ark-kb。

## 3. `result` 与 `totals` 怎么来

`result` 直接由 `manifest.result` 映射，**不做二次推断**：

| manifest.result | 回执 result |
|---|---|
| `PASS` | `pass` |
| `FAIL` | `fail` |
| `BLOCKED` | `blocked` |
| `INVALID` | `invalid` |
| `ERROR` / `NEEDS_REVIEW` | `needs_review` |

其它取值一律 exit 2（不允许静默降级成某个默认结果）。

`totals` 全部来自 `summary_final.json`，缺字段按 0 兜底：

- `rounds` ← `completed_rounds`
- `recognized` / `failed` / `recognition_rate` ← `normal_window.*`
- `boundary_unexpected` ← `boundary_window.unexpected_results`
- `serial_error_kinds` ← `len(serial_errors)`（**种类**，不是次数）
- `warning_markers` ← `sum(warning_marker_round_counts.values())`（**次数**）
- `archived_files` / `archived_bytes` ← 由 `manifest.files` 现算，不信任 summary 自报
- `status_counts` ← `status_counts`，有才带

`failures[]` 由 summary 派生：

| 条件 | 产出的 failure | attribution |
|---|---|---|
| `normal_window.failed > 0` | 唤醒/命令词识别失败 | `device` |
| `boundary_window.unexpected_results > 0` | 边界窗口出现非预期结果 | `corpus` |
| `summary.error` 非空 | 运行期错误（截断 500 字） | `tool` |

`confidence` 派生：`--confidence` 显式给出优先；否则 `result == pass` 且
`rounds > 0` 且 `failed == 0` 为 `high`，其余 `medium`。

## 4. 退出码

`ark_receipt.py`：

| 码 | 含义 |
|---|---|
| 0 | 成功（含 `--dry-run`） |
| 2 | 参数/输入/校验失败：缺 `run_id/node/project`、manifest 条目非法（path 缺失或 sha256 不是 64 位小写 hex）、时间无法解析、`result` 无法映射、`--lessons/--bugs` 不是数组 |
| 3 | 本地文件哈希与 manifest 不一致，拒绝生成回执 |
| 5 | 缺少共享时间库 `lib/ark_time.py` 或运行环境依赖 |

`ark-receipt.sh` / `ark-receipt.ps1`：

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 参数/输入错误 |
| 3 | 回执回传后哈希不一致 |
| 4 | 传输失败（取 manifest、建目录、scp 回传、认证不可用） |
| 5 | 缺少 `python3` / Python 3（bash 与 PowerShell 均如此） |

包装器的 `--upload` 会写 `<root>/receipts/<node>/<project>/<run_id>/run.receipt.json`，
**并在远端重算 sha256 后比对**，不一致即 exit 3。这一步不允许绕过。

## 5. 机器可读输出

普通模式 stdout：

```text
VERIFY=local_files=3/3 mismatches=0
RECEIPT=/tmp/r.json
RECEIPT_SHA256=5ddbc446e20aab818b406a36ebf68734084c4809b766a9cb2eac0070aa4bac33
EVIDENCE_DIR=/srv/storage/ark/results/demo/demo/20261110_120000
EVIDENCE_FILES=3 BYTES=50
RESULT=pass CONFIDENCE=medium
```

`--dry-run` 时 stdout 只输出回执 JSON（可直接 `| jq .`），`VERIFY=` / `RESULT=` / 落盘提示
改走 stderr。

## 6. 完整示例

> 说明：仓库当前 `fixtures/` 为空，因此下面的示例由一份**临时构造的 3 文件归档**生成，
> 目的只是展示真实形状。原始结果目录是 `D:\work\demo\20261110_120000`，manifest 里
> `archived_at` 故意写成 `2026-11-10T04:31:00Z`（UTC），用来证明输入宽松、输出一律北京时间。

命令：

```bash
python3 bin/ark_receipt.py \
  --manifest /tmp/arkfx/archive/manifest.json \
  --summary  /tmp/arkfx/archive/summary_final.json \
  --node demo --project demo --run-id 20261110_120000 \
  --out /tmp/r.json
```

回执（节选为完整结构，`evidence_sha256` 与 `manifest_sha256` 为真实计算值）：

```json
{
  "schema": "run.receipt.v1",
  "run_id": "20261110_120000",
  "task": "demo 压测归档（20261110_120000）",
  "skill": "lstest",
  "skill_version": "unknown",
  "scope": {"device": "DEMO-DEV", "project": "demo", "firmware": null, "platform": "demo (DEMO-DEV)"},
  "result": "pass",
  "totals": {
    "rounds": 10, "target_rounds": 10, "duration_minutes": 30,
    "recognized": 9, "failed": 1, "recognition_rate": 0.9,
    "boundary_unexpected": 0, "serial_error_kinds": 1, "warning_markers": 3,
    "archived_files": 3, "archived_bytes": 50,
    "status_counts": {"RECOGNIZED": 9, "NOT_RECOGNIZED": 1}
  },
  "failures": [
    {"name": "唤醒/命令词识别失败", "reason": "正常窗口 1 轮未识别（识别率 0.9）",
     "attribution": "device", "evidence": ["summary_final.json"]}
  ],
  "bugs_found": [],
  "evidence_dir": "/srv/storage/ark/results/demo/demo/20261110_120000",
  "evidence_sha256": [
    "4ef205e0ef04a083e71e35bb9955323629177d18abb008d12644b8eb0acbb987",
    "1a620197ce70e74d11129474c47e76c89806caeb4b551f4bde8960ac9d4e8061",
    "45a18fb54138a2921002909f51641eb8a3508b23ed6297b49146368eb3ada7e6"
  ],
  "evidence_files": [
    {"path": "rounds.csv", "sha256": "4ef205e0…", "bytes": 26},
    {"path": "tool.log", "sha256": "1a620197…", "bytes": 14},
    {"path": "logs/COM3.log", "sha256": "45a18fb5…", "bytes": 10}
  ],
  "lessons": [],
  "confidence": "medium",
  "started_at": "2026-11-10 12:00:00",
  "ended_at": "2026-11-10 12:30:05",
  "notes": "回执由归档 manifest 自动生成：node=demo project=demo archived_at=2026-11-10 12:31:00 files=3 bytes=50；源目录 D:\\work\\demo\\20261110_120000",
  "tags": ["archive", "demo", "pass"],
  "archive": {
    "node": "demo", "project": "demo", "storage_root": "/srv/storage/ark",
    "archived_at": "2026-11-10 12:31:00",
    "source_dir": "D:\\work\\demo\\20261110_120000",
    "manifest_sha256": "9f8a96368bd9e02a6ba5e0d7836fa939d570b1e4a7c86df002a72c849e700cbd"
  }
}
```

同一份 manifest 加 `--legacy-rfc3339` 后，只有三处时间变化：

```diff
-  "started_at": "2026-11-10 12:00:00",
-  "ended_at": "2026-11-10 12:30:05",
+  "started_at": "2026-11-10T12:00:00+08:00",
+  "ended_at": "2026-11-10T12:30:05+08:00",
...
-    "archived_at": "2026-11-10 12:31:00",
+    "archived_at": "2026-11-10T12:31:00+08:00",
```
