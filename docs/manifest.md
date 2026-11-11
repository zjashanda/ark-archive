# manifest v1

`manifest.json` 是每次归档的**清单与存证**：它记录这次 run 是谁、在哪个节点、跑了多久、结果如何，以及每一个被归档文件的字节数和 SHA-256。归档完成后，远端校验脚本只信这张清单——逐个重算哈希，全对才把暂存目录转正。

机器可读约束见 [`schemas/manifest.v1.json`](../schemas/manifest.v1.json)。

## 字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema` | string | 是 | 固定 `manifest.v1` |
| `run_id` | string | 是 | 本次 run 的目录名，形如 `20261110_120000` |
| `project` | string | 是 | 项目名，对应存储上的 `<project>` 段 |
| `node` | string | 是 | 执行节点名，对应存储上的 `<node>` 段 |
| `device` | string | 是 | 被测设备名，默认与 `node` 相同 |
| `result` | string | 是 | `PASS` / `FAIL` / `unknown`，推导规则见下 |
| `started_at` | string | 是 | 开始时间，**北京时间无时区** `YYYY-MM-DD HH:MM:SS` |
| `ended_at` | string | 是 | 结束时间，格式同上 |
| `archived_at` | string | 是 | 归档时间，格式同上 |
| `source_dir` | string | 是 | 源目录绝对路径（记录用，不参与校验） |
| `files` | array | 是 | 文件清单，见下 |
| `files[].path` | string | 是 | 相对源目录的路径，`/` 分隔，不含 `..` |
| `files[].bytes` | integer | 是 | 文件字节数 |
| `files[].sha256` | string | 是 | 64 位小写十六进制 SHA-256 |
| `raw_started_at` | string | 否 | 源数据里的**原始**开始时间，原样保留 |
| `raw_ended_at` | string | 否 | 源数据里的**原始**结束时间，原样保留 |

## 时间契约

`started_at`、`ended_at`、`archived_at` 三个字段属于用户可见时间，一律北京时间、无时区后缀（规则见 [time-contract.md](time-contract.md)）：

```json
"started_at": "2026-11-10 10:15:30"
```

**不允许**出现 `2026-11-10T10:15:30`、`2026-11-10T10:15:30+08:00`、`2026-11-10T02:15:30Z`。  <!-- time-lint:allow 反例/legacy 样例 -->

数据源里原本带时区的时间（设备日志、`summary_final.json`）在转换后，原文写入 `raw_started_at` / `raw_ended_at`。这样“用户看到的是北京时间”与“可追溯到原始来源”两件事同时成立。

旧消费者若必须读 RFC3339，用 `--legacy-rfc3339`（仅影响 `archived_at`）显式开启，属于废弃路径。

## 推导规则

**时间**：优先取 `summary_final.json` 的 `started_at` / `ended_at`；缺失时退回文件 mtime 的最早与最晚值；仍缺失则记为归档时刻。原始字符串一并存入 `raw_*`。

**结果**：

1. `summary_final.json` 有 `recognition_rate`：`>= 0.9` 记 `PASS`，否则 `FAIL`；
2. 没有识别率但有 `status_counts`：按其中的键判定 `PASS` / `FAIL`；
3. 两者都没有：记 `unknown`，归档照做，但不声称通过。

**文件清单**：递归遍历源目录，跳过符号链接（避免把归档变成任意路径读取），跳过目录本身，按路径字典序输出，保证同一输入树在 Linux 与 Windows 上产出**完全一致**的清单。

## 示例

```json
{
  "schema": "manifest.v1",
  "run_id": "20261110_120000",
  "project": "tcl-r5",
  "device": "win009",
  "node": "win009",
  "result": "PASS",
  "started_at": "2026-11-10 10:15:30",
  "ended_at": "2026-11-10 10:41:10",
  "files": [
    {
      "path": "serial_logs/a.log",
      "bytes": 5,
      "sha256": "deb055d836e44a1dcf0317b0cacac2dbdd36301f82abf787f7849d3f5b916750"
    },
    {
      "path": "summary_final.json",
      "bytes": 127,
      "sha256": "7df9e5384242b3df313f6ac862ccb05734b2bb1d5ed43fb63dc14abf089aa172"
    },
    {
      "path": "tool.log",
      "bytes": 2000,
      "sha256": "b03f0a8f6f799420f1afbccdd0485e433430ca4e17d87c7d6c0cf26c4103b883"
    }
  ],
  "archived_at": "2026-11-10 19:08:28",
  "source_dir": "/tmp/fx",
  "raw_started_at": "2026-11-10T02:15:30Z",  <!-- time-lint:allow 反例/legacy 样例 -->
  "raw_ended_at": "2026-11-10T02:41:10Z"  <!-- time-lint:allow 反例/legacy 样例 -->
}
```

## 与存储路径的关系

归档正式目录是：

```
<results-root>/<node>/<project>/<run_id>/
```

清单里的 `files[].path` 是相对 `<run_id>/` 的路径。因此“清单 + 目录”一起才构成完整存证：清单说每个文件应当是什么哈希，目录里放实际字节。二者不一致时，`lib/remote-verify.sh` 拒绝转正并把暂存目录移入隔离区。

## 版本演进

`schema` 字段是唯一的版本锚点。新增可选字段不升版本；删除字段、改变字段语义或改时间格式必须升到 `manifest.v2`，并在 `CHANGELOG.md` 说明迁移方式。
