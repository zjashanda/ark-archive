# 归档完成条件与回流契约（v2 · 事件驱动）

本文件是 ark-archive 侧的**回流契约落地说明**：知识回流在哪些生命周期时刻落检查点、归档什么时候
才算完成、回执里的回流字段由谁写、顺序为什么不能颠倒，以及 `DELIVERY_INCOMPLETE` 在归档侧怎么判定。

- 上游规格：NOAH-66 的 `kb-sync-proposal-v2.md`（v2.0.0，下称「提案 v2」）。字段名、枚举值以提案
  §1、§2 为准，本文不另立字段。v1.0.0 的「任务结束一次性回流」已被取代，仅作为历史保留；
  两份冲突时以 v2 为准。
- 机器可读约束：[`schemas/receipt.v1.json`](../schemas/receipt.v1.json)（JSON Schema draft-07）。
  本轮只增一个**可选**顶层属性 `checkpoints`，`required` 一字未动，`archive` 子对象不动。
- 相邻文档：[`receipt.md`](receipt.md) 讲回执字段与生成器，[`manifest.md`](manifest.md) 讲清单与哈希，
  [`gate-mapping.md`](gate-mapping.md) 讲门禁事件与回执的对应、以及三层回执。本文只覆盖「归档 → 回流」，
  其余内容一律互链，不重复抄写。
- 时间口径统一走 [`time-contract.md`](time-contract.md)：北京时间、无时区标记。

## 0. v1 → v2 到底改了什么

| 维度 | v1（end-only，历史） | v2（本版，生效） |
|---|---|---|
| 回流时机 | 任务正常结束一次 | 生命周期事件逐次写 checkpoint，结束只做聚合与关闭 outbox |
| 失败路径 | 没有知识产出 | `BLOCKED` / `FAIL` / 心跳丢失 / 中断 / 取消都有检查点 |
| 持久化 | 直接写知识库 | 先写任务目录内 append-only WAL/outbox，再异步归档入库 |
| 幂等键 | `run_id` | `issue_id + run_id + stage + event_seq + evidence_digest` |
| 作用域 | 单层 scope | 多作用域 + 引用（不复制孤岛）+ 提升/降级 |
| 质量 | 三分层 | 三分层不变，但失败知识可 `formal`（bug/method），崩溃残留只能 `candidate` |

结论只有一句：**结束不是回流的唯一时机，失败和中断同样必须留下知识**。归档侧要保证的，是这些
事件先落盘、可重放、可核对，而不是等任务「正常收尾」才想起知识。

## 1. 归档完成条件（v1 的判定继续有效）

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

v2 在这五条之上再加一条：**WAL 与检查点副本必须一起进归档**（见第 5 节）。只归档证据、不归档
回流事件，等于把知识来源留在了跑测机上，下一次 run 无从重放。

## 2. 事件驱动：12 个检查点触发器

写入原则：

1. 事件发生时**立即**写 WAL，不等任务结束；
2. WAL 落盘成功之前，不得开始对应的归档或入库动作；
3. 同一个事件重放只允许命中同一个 `checkpoint_id`，不得新建语义条目。

`trigger` 是封闭枚举，共 **12 个**值。`FINAL_RECEIPT` 不在其中：它不是知识检查点，只做聚合与
关闭 outbox（见第 9 节）。提案 §1.4 里 `FINAL_RECEIPT` 那一行描述的是收尾动作，不是追加新事件。

| # | `trigger` | 生命周期时刻 | 写入方 | 默认质量 |
|---|---|---|---|---|
| 1 | `EXECUTION_CHECK` | 预检完成后立即 | 执行侧 | `formal`（仅元数据） |
| 2 | `STAGE_FINISHED` | 每个阶段结束（PASS 或 FAIL 都写） | 执行侧 | 证据完整 ⇒ `formal` |
| 3 | `BLOCKED` | 判定阻塞的当下，不等收尾 | 执行侧 | 有现象+attempts+证据 ⇒ `formal` |
| 4 | `FAIL` | 判定失败的当下 | 执行侧 | 有现象+attempts+证据 ⇒ `formal` |
| 5 | `NEEDS_REVIEW` | 结论需人工复核时 | 执行侧 | 有证据 ⇒ `formal`，否则 `candidate` |
| 6 | `WATCHDOG_RUNNING_NO_EVIDENCE` | 看门狗发现「在跑但无落盘证据」 | 看门狗 | `candidate` |
| 7 | `WATCHDOG_STATE_DRIFT` | 看门狗发现状态与事实漂移 | 看门狗 | `candidate` |
| 8 | `WATCHDOG_TIMEOUT` | 看门狗超时判定 | 看门狗 | `candidate` |
| 9 | `WATCHDOG_HEARTBEAT_LOST` | 看门狗发现心跳丢失 | 看门狗 | `candidate` |
| 10 | `MANUAL_CANCEL` | 人工取消；由恢复器或下一次 run 补写 | 恢复侧 | 有证据 ⇒ `candidate`，无证据 ⇒ `evidence_gap` |
| 11 | `RUNTIME_CRASH` | 进程崩溃；由下一次 run 扫描 WAL 补写 | 恢复侧 | 有证据 ⇒ `candidate`，无证据 ⇒ `evidence_gap` |
| 12 | `RECOVERY_REPLAY` | 下一次 run 启动时补发未完成 outbox | 恢复侧 | 不新建语义，沿用被重放事件的质量 |

`EXECUTION_CHECK` 只记录环境、能力、输入版本与知识库基线，**不产出结论性知识**；它的价值是让
后续每条知识都能回答「当时是什么环境」。

## 3. WAL 与 checkpoint 事件

检查点事件的第一落点是任务目录内的 append-only WAL，不是归档目录，也不是知识库：

```text
<tasks-id>/receipts/outbox/checkpoints-<YYYYMMDD>.jsonl   # WAL，一行一个事件
<tasks-id>/receipts/outbox/outbox.json                    # 状态索引，可由 WAL 重建
<tasks-id>/receipts/outbox/archived/<checkpoint_id>.json  # 归档后的逐条副本
```

- WAL **只追加**：不覆盖、不改写、不删除；按天切分，跨天不合并。
- 任何 archive / ingest 动作之前，对应事件必须已经在 WAL 里可见。
- `outbox.json` 是索引不是真源，损坏时按 WAL 重建，重建过程不丢事件。
- `archived/<checkpoint_id>.json` 是归档副本；失败重试时覆盖同 id 副本，不新增语义条目。

事件形状（`ark.checkpoint.v1`）关键字段：

```json
{
  "schema": "ark.checkpoint.v1",
  "checkpoint_id": "<64 位小写 hex>",
  "issue_id": "NOAH-66",
  "run_id": "20261112-150000_noah-66",
  "stage": 15,
  "event_seq": 3,
  "trigger": "STAGE_FINISHED",
  "at": "2026-11-12 17:35:00",
  "quality": "formal",
  "scope": {"level": "capability", "key": "flashing", "parent": "global"},
  "evidence": [{"path": "result/x.md", "sha256": "<64 位小写 hex>", "bytes": 0}],
  "outbox": {"archive_status": "pending", "kb_ingest_status": "pending",
             "kb_query_back_status": "pending", "retry": {"attempts": 0, "last_error": ""}}
}
```

### 3.1 幂等公式

```text
checkpoint_id = sha256(issue_id + "|" + run_id + "|" + stage + "|" + event_seq + "|" + evidence_digest)
evidence_digest = sha256(按 sha256 排序后依次拼接的所有 evidence[].sha256)
```

- `evidence` 为空时，`evidence_digest` 取空串的 sha256，不允许省略该段。
- 同一个 `checkpoint_id` 再次 append：直接跳过并返回已有状态，不新建条目、不重复入库。
- 幂等键里带 `stage` 与 `event_seq`，因此同一 run 的多阶段、多事件不会互相覆盖。
- 幂等键里带 `evidence_digest`，因此「同一事件后来补齐证据」会产生新 id，而不是改写旧事件。

## 4. outbox 状态机与关闭条件

每个检查点在 `outbox` 里有三个独立状态位，各自由单一写入方维护：

| 状态位 | 取值 | 写入方 |
|---|---|---|
| `archive_status` | `pending` / `partial` / `ok` / `failed` / `skipped` | ark-archive |
| `kb_ingest_status` | `pending` / `recorded` / `skipped_no_kb` / `failed` | ark-kb |
| `kb_query_back_status` | `pending` / `pass` / `fail` / `deferred` | ark-kb |

状态机单向推进，允许失败回退到可重试态，不允许跳过：

```text
pending → partial → ok
pending → failed → pending（重试）
kb: pending → recorded | skipped_no_kb | failed → pending（重试）
query: pending → pass | deferred | fail
```

**outbox 关闭条件**（所有检查点都满足才关闭）：

```text
∀ checkpoint:
    archive_status == ok
    且 kb_ingest_status ∈ {recorded, skipped_no_kb}
    且 kb_query_back_status ∈ {pass, deferred-with-reason}
→ outbox 关闭
否则 → outbox 未关闭，FINAL_RECEIPT 不得判 PASS
```

- `deferred` 必须带原因（跨节点暂不可见、索引延迟等），空原因的 `deferred` 视为未关闭。
- `skipped_no_kb` 必须带封闭集合内的原因，静默跳过按 `DELIVERY_INCOMPLETE` 处理。
- 重试只追加 `retry.attempts` 与 `retry.last_error`，不新建事件、不改 `checkpoint_id`。
- 归档侧只写 `archive_status` 与自己产出的清单哈希，其余状态位一律交给 ark-kb 回填。

## 5. 归档侧职责

归档侧不产生知识，只负责把知识事件的证据链完整搬运：

1. **复制 WAL**：把 `receipts/outbox/checkpoints-<YYYYMMDD>.jsonl` 复制进
   `results/<node>/<project>/<run_id>/outbox/`，跨天则复制涉及的每一天。
2. **复制检查点副本**：把 `receipts/outbox/archived/<checkpoint_id>.json` 复制进同一目录。
3. **进 manifest**：WAL 与检查点副本都是普通归档文件，必须出现在 `manifest.json` 的 `files[]` 里，
   带 `path` / `bytes` / `sha256`，参与第 1 节的逐字节复算。
4. **永不删除**：源 WAL、源副本、归档副本都不删；重跑产生新目录，不覆盖旧证据。
5. **失败重试**：网络或远端临时失败按 1 / 2 / 4 分钟退避重试 3 次，仍失败则 `archive_status=failed`。
6. **半途标记**：run 在复制中途死掉时，已复制的部分标 `archive_status=partial`；WAL 里存在、
   但归档目录没有对应副本的检查点标 `orphan=true`。`partial` 与 `orphan` 都必须阻塞 outbox 关闭，
   等下一次 run 补齐或人工处理，不能当作 `ok`。

`partial` 是检查点级状态，不改变 `delivery.archive_status` 的四值语义；整批归档是否成功仍以
`manifest.json` 与第 1 节五条为准。

## 6. 崩溃、取消与重放

- 崩溃与取消不再意味着「这次 run 没有知识」。下一次 run 启动时先扫描
  `receipts/outbox/checkpoints-*.jsonl`，按 `checkpoint_id` 去重，再对未完成 outbox 补发
  `RECOVERY_REPLAY`。
- `RECOVERY_REPLAY` 不新建语义条目，只推进状态；被它重放的原始事件保持原 `trigger` 与 `at`。
- `MANUAL_CANCEL` / `RUNTIME_CRASH` 若在进程死亡前没来得及写，由恢复侧按最后已落盘事件补写；
  完全无证据时质量只能是 `evidence_gap`，不得补写成 `formal`。
- 重放全程 append-only：不删旧事件、不改旧行、不把 `failed` 直接改写成 `ok`（只能新增状态推进记录）。
- 平台若没有取消/崩溃钩子（提案 v2 §6 的 P13），重放责任落到下一次 run；这不是跳过回流的理由。

## 7. 质量分层与提升

| 情形 | 层 | 能否驱动 dispatch |
|---|---|---|
| 正常阶段、证据完整 | `formal` | 可以 |
| `BLOCKED` / `FAIL` 且有现象、attempts、证据 | `formal`（type=bug/method） | 可以（作为恢复建议/stop rule） |
| 进程崩溃、证据不完整 | `candidate` | 不可以，仅作提示 |
| 只有推测、没有证据 | `evidence_gap` | 不可以 |

失败知识可以是 `formal`，但**不可能判 PASS**：失败路径的 `outcome` 只能是 fail / blocked /
needs_review，`result` 不得写成 pass。`formal` 描述的是证据强度，不是结果好坏。

后续 run 补齐证据 ⇒ `candidate → formal`；旧条目置 `status=superseded`，`superseded_by` 指向新条目，
`lineage[]` 保留追溯链。**永不删除历史条目**，降级同理，只追加限定条件或 `exceptions`。

## 8. 作用域：只引用，不改写

- 归档原样保存 `scope_level`、`scope_key`、`parent` 与 `derived_from`，字段值逐字保留，不归一化、
  不猜测、不合并层级。
- 归档**不解释**作用域：判断「项目条目能否覆盖全局事实」「是否该提升到 capability」是 ark-kb 与
  dispatch 的职责；归档只保证引用链完整。
- 项目层只能以「约束/例外」方式影响更广层事实，`derived_from` 指向源条目，不复制正文。
- 跨节点不可见时，`kb_query_back_status` 只能写 `deferred` 并记录原因，不得改写成 `pass`，
  也不得因此上报归档 PASS。

## 9. `FINAL_RECEIPT` 只聚合与关闭

`FINAL_RECEIPT` 是收尾动作，不是第 13 个检查点：

- 它把本次 run 的检查点摘要聚合到回执的可选顶层字段 `checkpoints[]`，每条只保留
  `checkpoint_id` / `trigger` / `quality` / `at` 四个字段（完整事件仍在 WAL 与归档里）。
- 它读取 outbox 状态并判定关闭条件（第 4 节），关闭与否写进 `delivery`。
- 它**不产生新知识**、不追加新的语义检查点、不改写已有事件。
- `checkpoints[]` 是投影不是真源：与 WAL 冲突时以 WAL 为准，回执只做摘要，缺失可重建。

`DELIVERY_INCOMPLETE` 判定在 v2 下以 outbox 关闭条件为准：

```text
archive_status=ok
  且 outbox 已关闭（所有 checkpoint 满足第 4 节三个状态位）
→ 允许 PASS
否则 → DELIVERY_INCOMPLETE
```

`archive_status=ok` 但 outbox 未关闭（还有 `pending` / `partial` / `failed` / 空原因 `deferred`），
按 incomplete 处理；`FINAL_RECEIPT` 只能是 `NEEDS_REVIEW` 或 `blocked`。缺哪一格写哪一格，
不允许用「归档已经成功」代替整体结论。

## 10. 归档不是验收

归档证明的是**字节与事件被完整保存**，不是**结论正确**：

- `archive_status=ok` 只说明 manifest、证据、WAL 都落盘且哈希一致，不说明测试通过、门禁通过。
- 验收结论属于 `gate-mapping.md` 的门禁事件与 `FINAL_RECEIPT`；归档侧无权把 `ok` 解读成 PASS。
- `DELIVERY_INCOMPLETE` 时即使证据齐全，也只能判 `NEEDS_REVIEW` / `blocked`。
- 反过来说，`FAIL` / `BLOCKED` 的 run 依然可以归档成功，且必须写检查点——归档完成与结果好坏是两条轴。

## 11. 顺序不变式（v2）

```text
（每个事件）WAL → 归档复制 → ingest → query-back
（整次 run）manifest → receipt → archive → record → query-back → FINAL_RECEIPT 聚合
```

1. **WAL 先于 archive / ingest**：事件没落盘就归档，等于知识来源不可重放。
2. **manifest 先于 receipt**：回执的 `evidence_sha256`、`evidence_files[]`、`archive.manifest_sha256`
   全部从 manifest 派生；manifest 没定稿就生成回执，是给一份还会变的清单盖章。
3. **receipt 先于 archive 完成**：回执照 manifest 复算哈希，是归档「校验通过」的判据本身。
4. **archive 先于 record**：知识条目要引用受控资产位置与 `archive_manifest_sha256`；
   归档未完成就入库，条目指向不存在的证据目录。
5. **record 先于 query-back**：query-back 是在相同维度再查一次，确认新条目可见；没入库就查，
   `pass` 无从谈起。

跳步的直接后果是 `DELIVERY_INCOMPLETE`；跳步后再回头补做不算修复，因为中间产物已带着错的证据引用。

## 12. 与既有文档的关系

| 文档 | 负责什么 | 本文如何引用 |
|---|---|---|
| [`manifest.md`](manifest.md) | 清单字段、sha256、时间契约 | 第 1 节条件 1/2/4 与第 5 节 `files[]` 依赖它 |
| [`receipt.md`](receipt.md) | 回执字段、生成器、退出码 | 第 9 节 `checkpoints[]` 挂在它的顶层 |
| [`gate-mapping.md`](gate-mapping.md) | 门禁事件、`run_id` 关联、三层回执、`FINAL_RECEIPT` 材料 | 第 9/10 节的 PASS/`NEEDS_REVIEW` 判定与它一致 |
| 本文 | 归档完成条件与事件驱动回流 | 只补「归档 → 回流」，不复制上述三份的内容 |

一句话分工：`manifest.md` 说清单长什么样，`receipt.md` 说回执长什么样，`gate-mapping.md` 说事件
怎么对上，本文说这些产物**凑齐什么才算归档闭环、检查点何时落盘**。

## 13. 本轮不做什么

- 不改 `schemas/receipt.v1.json` 的 `required`，不动 `archive` 子对象，不动任何既有 `$defs`。
- 不改 `bin/ark-archive*`、`bin/ark_receipt.py` 的行为，不加 CLI 参数，不新增依赖。
- 不写 ark-kb 的 `record` / `query-back` 实现，不在本仓执行入库或状态回填。
- 不实现 WAL 写入器与重放器，只定义契约；实现落在 ark-kb / ark-node 的后续变更。
- 不发 OSS、不推 PR：本轮只交分支与提交，canonical 合入与发布另走审批。
- 不伪造跨节点可见性结论：`deferred` 就是 `deferred`，等平台能力补齐再谈 pass。
