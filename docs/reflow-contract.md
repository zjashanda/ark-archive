# 归档完成条件与回流契约

本文件是 ark-archive 侧的**回流契约落地说明**：归档什么时候才算完成、回执里的回流触发字段由谁写、
顺序为什么不能颠倒，以及 `DELIVERY_INCOMPLETE` 在归档侧怎么判定。

- 上游规格：NOAH-66 的 `kb-sync-proposal.md`（下称「提案」）。字段名以提案 §1.1、§2.2 为准，本文不另立字段，
  也不改写提案里的枚举值。
- 机器可读约束：[`schemas/receipt.v1.json`](../schemas/receipt.v1.json)（JSON Schema draft-07）。
  本轮只增两个**可选**顶层属性，`required` 一字未动。
- 相邻文档：[`receipt.md`](receipt.md) 讲回执字段与生成器，[`manifest.md`](manifest.md) 讲清单与哈希，
  [`gate-mapping.md`](gate-mapping.md) 讲门禁事件与回执的对应、以及三层回执。本文只覆盖「归档 → 回流」，
  其余内容一律互链，不重复抄写。
- 时间口径统一走 [`time-contract.md`](time-contract.md)：北京时间、无时区标记。

## 1. 归档完成条件

归档只有在一组事实**同时**成立时才算完成。缺任何一条，归档侧只能给出 `archive_status=failed`，
不得在回执、Issue 评论或汇报里声称「归档完成」。

| # | 条件 | 归档侧证据 |
|---|---|---|
| 1 | `manifest.json` 存在，且 `files[]` 非空 | `<storage_root>/results/<node>/<project>/<run_id>/manifest.json` |
| 2 | 每个归档文件的实际 sha256 与 `files[].sha256` 一致 | 归档后重新计算，不采信源侧数字 |
| 3 | `archived_at` 是北京时间 `YYYY-MM-DD HH:MM:SS` | 无 `T`、无 `Z`、无时区偏移，正则见 schema |
| 4 | `source_dir` 可追溯 | 指向跑测机上的原始结果目录，不是暂存目录 |
| 5 | 回执 `evidence_sha256` 与 manifest 的 `files[].sha256` 一致 | 集合必须相等；回执按 manifest 顺序展开 |

第 2 条是唯一不能靠「字段齐全」蒙过去的一条：文件落盘后必须逐字节复算，损坏文件按
[`receipt.md`](receipt.md) 的记录以退出码 3 结束，整批进 `_quarantine`，正式目录不出现半成品。

`files[]` 为空不是「空任务」，而是「没有可归档的证据」——这种 run 不构成归档，也不要写一条
看似成功的回执去占位。

## 2. 回流触发字段

回流状态放在回执的可选顶层字段 `delivery`，形状为 `ark.delivery.v1`（提案 §2.2），
同时落到任务目录的 `receipts/delivery.json`。字段名完全照抄提案，不做简化：

```json
{
  "schema": "ark.delivery.v1",
  "run_id": "",
  "idempotency_key": "sha256(scope+run_id)",
  "archive_status": "pending|ok|failed|skipped",
  "archive_manifest_sha256": "",
  "kb_ingest_status": "pending|recorded|skipped_no_kb|failed",
  "kb_entry_ids": [],
  "kb_query_back_status": "pending|pass|fail|deferred",
  "kb_query_back_at": "",
  "kb_query_back_hits": [],
  "no_kb_reason": "",
  "retry": {"attempts": 0, "last_error": ""},
  "updated_at": ""
}
```

写入方按职责切开，**同一个字段只有一个写入方**：

| 字段 | 写入方 | 写入时机 |
|---|---|---|
| `archive_status` | ark-archive | 归档校验结束（成功或失败）后立即写 |
| `archive_manifest_sha256` | ark-archive | 同上，取自 `archive.manifest_sha256` |
| `kb_ingest_status` | ark-kb | `record` 返回后 |
| `kb_entry_ids` | ark-kb | `record` 返回后，按返回顺序 |
| `kb_query_back_status` | ark-kb | `query-back` 返回后 |
| `kb_query_back_at` / `kb_query_back_hits` | ark-kb | 同上 |

ark-archive **不**写另外三个状态位，也不替 ark-kb 猜结果：归档结束时的 `delivery` 只带
`archive_status` 与 `archive_manifest_sha256`，其余保持 `pending` 或空缺，交给 ark-kb 补。

两个可选契约（`kb_context`、`delivery`）都允许缺失：老的生成器、老的消费方不看这两个键也能工作，
这是本轮只增可选属性的原因。但**一旦使用就必须成对出现**：`kb_context` 在开工前写，`delivery` 在归档后写。
只有 `delivery` 没有 `kb_context`，说明这个 run 没有查询留痕，回流链条从一开始就断了，
同样按 `DELIVERY_INCOMPLETE` 处理。

`schema` 里的两个新属性刻意写成 `{"type": "object"}` 加一行 `description`，不内联完整子 schema：
完整字段约束由 ark-kb 的 `schema/kb-context.v1.json`、`schema/delivery.v1.json` 单点维护，
两边抄两份必然漂移。根对象也继续保持**不设** `additionalProperties`，让消费方能附加自己的字段。

## 3. 顺序不变式

```text
manifest → receipt → archive → record → query-back
```

五步是单向的，不能并行、不能插队、不能补做：

1. **manifest 先于 receipt**：回执的 `evidence_sha256`、`evidence_files[]`、`archive.manifest_sha256`
   全部从 manifest 派生。manifest 没定稿就生成回执，等于给一份还会变的清单盖章。
2. **receipt 先于 archive 完成**：回执照着 manifest 复算哈希，是归档「校验通过」的判据本身。
   先宣布归档成功再补回执，就变成了自证。
3. **archive 先于 record**：ark-kb 的条目要引用受控资产位置与 `archive_manifest_sha256`。
   归档未完成就入库，条目指向一个不存在的证据目录。
4. **record 先于 query-back**：query-back 是在**相同维度**下再查一次，确认新条目出现在默认 top 20。
   没入库就查，查到的必然是空结果，"pass" 无从谈起。

跳步的直接后果是 `DELIVERY_INCOMPLETE`；跳步后再回头补做不算修复，因为中间产物已经带着错的证据引用。

## 4. `DELIVERY_INCOMPLETE`

判定（提案 §3.1）：

```text
archive_status=ok
  且 ( kb_ingest_status=recorded 且 kb_query_back_status=pass )
  或 ( kb_ingest_status=skipped_no_kb 且 no_kb_reason 非空 )
→ 允许 PASS
否则 → DELIVERY_INCOMPLETE
```

归档侧只对自己那一格负责，但必须如实把判定要用的输入摆出来：

- `archive_status` 不是 `ok`，后续状态位一律不会被消费，`DELIVERY_INCOMPLETE` 无需再讨论。
- `archive_status=ok` 但 `delivery` 缺失或没有 `archive_manifest_sha256`，视为契约不全，按 incomplete 处理。
- `DELIVERY_INCOMPLETE` 时 `FINAL_RECEIPT` **不得**判 PASS，只能是 `NEEDS_REVIEW` 或 `blocked`；
  缺的是哪一格就写哪一格，不允许用「归档已经成功」代替整体结论。
- 静默跳过是禁止项：无知识价值时必须 `kb_ingest_status=skipped_no_kb`，且 `no_kb_reason` 取自提案 §2.3
  的封闭集合（`no-new-knowledge`、`pure-inventory`、`duplicate-of-existing:<entry_id>`、
  `sensitive-not-indexable`）。

## 5. 归档语义：只复制、可重试、不越权上报

- **只复制不移动**：归档是复制到存储根，源任务目录保持原样。回执也是只生成不覆盖；
  同一 `run_id` 重跑产生新目录，不覆盖旧证据。
- **失败重试 3 次**：网络或远端临时失败按指数退避重试，间隔 1 分钟、2 分钟、4 分钟；
  每次尝试追加到 `delivery.retry`（`attempts` 与 `last_error`），不新建回执。
  3 次仍失败则 `archive_status=failed`，交人工。
- **跨节点不可见**：query-back 在别的节点查不到新条目时，只能写 `deferred` 并记录原因，
  **不得**改写成 `pass`，也不得因此上报归档 PASS。可见性问题归平台能力，不归归档脚本伪造。

## 6. 与既有文档的关系

| 文档 | 负责什么 | 本文如何引用 |
|---|---|---|
| [`manifest.md`](manifest.md) | 清单字段、sha256、时间契约 | 第 1 节的条件 1/2/4 直接依赖它 |
| [`receipt.md`](receipt.md) | 回执字段、生成器、退出码 | 第 2 节的两个可选字段挂在它的顶层 |
| [`gate-mapping.md`](gate-mapping.md) | 门禁事件、`run_id` 关联、三层回执、`FINAL_RECEIPT` 材料 | 第 4 节的 PASS/`NEEDS_REVIEW` 判定与它一致 |
| 本文 | 归档完成条件与回流触发 | 只补「归档 → 回流」，不复制上述三份的内容 |

一句话分工：`manifest.md` 说清单长什么样，`receipt.md` 说回执长什么样，`gate-mapping.md` 说事件怎么对上，
本文说这些产物**凑齐什么才算这次 run 的归档闭环**。

## 7. 本轮不做什么

- 不改 `schemas/receipt.v1.json` 的 `required`，不动任何嵌套对象的 `additionalProperties: false`。
- 不改 `bin/ark-archive*`、`bin/ark_receipt.py` 的行为，不加 CLI 参数，不新增依赖。
- 不写 ark-kb 的 `record` / `query-back` 实现，不在本仓执行入库。
- 不发 OSS、不推 PR：本轮只交分支与提交，canonical 合入与发布另走审批。
- 不伪造跨节点可见性结论：`deferred` 就是 `deferred`，等平台能力补齐再谈 pass。
