# 归档物与门禁事件的映射

本文件说明 ark-archive 产出的 `run.receipt.v1` 与 `manifest.v1` 如何对应 NoahsArk 执行门禁。
门禁完整规则见 NOAH-66 的 `gate-plan-integration.md`（下称「整合规则」），本文只覆盖归档这一片：
关联键、回执分层、事件与 stage 索引、归档前必须齐的材料、回滚边界。

## 1. `run_id` 是唯一关联键

回执、manifest、归档目录三者之间只靠 `run_id` 对齐：

```text
<results-root>/<node>/<project>/<run_id>/          # manifest.json 与证据
<receipts-root>/<node>/<project>/<run_id>/run.receipt.json
```

`run_id` 同时是门禁侧的关联键：`FINAL_RECEIPT.receipt_path` 指向的回执、`STAGE_FINISHED.artifacts[]`
里的证据、以及下一轮 dispatch 的 `kb[]` 引用，都通过它反查。任何「用标题相似度关联两次运行」的做法
都不成立——同名任务重跑会有新的 `run_id`。

`manifest.v1` 另外带 `node` / `project` / `device`，它们只用于定位存储路径与知识范围，不参与门禁关联。

## 2. 回执不带 `stage`，也不许新增

整合规则 §7.3 的裁决是：`run.receipt.v1` 的字段集在本轮**一字未改**，`stage` 不写进回执正文。

- 回执的对象层（`scope`、`result_source`、`totals`、`archive`）均声明 `additionalProperties: false`，
  多写一个键会被 schema 直接拒绝；顶层字段集由 `required` 与两仓消费者共同锁定。
- 回执是**运行结论**，不是**运行过程**。一次 run 可能横跨多个 stage，把其中一个 stage 写进回执
  会让 `run_id:stage` 变成事实上的复合主键，与「`run_id` 唯一关联」冲突。
- 需要 stage 维度的消费方读 `receipts/events/gates-<YYYYMMDD>.jsonl` 与 `receipts/stage-index.json`，
  这两个文件在任务目录内，不受仓库 schema 约束。

要给回执加 `stage`，必须先做 `receipt.v2` 升版评审并同步两仓消费者，不得就地改 v1。

## 3. 三层回执

只有第一层可以进入归档后的知识回流与下一轮 dispatch。

| 层 | 位置 | 性质 | 能否进 ark-kb |
|---|---|---|---|
| 正式 `formal` | `receipts/run.receipt.json` | 合约全字段、`evidence_sha256` 可核、`result` 已归一 | 可以 |
| 候选 `candidate` | `receipts/candidates/<name>.json` | 结论未复核，或证据只覆盖部分场景 | 不可以 |
| 证据缺口 `evidence-gap` | `receipts/evidence-gaps/<name>.json` | 明确缺失的证据清单与补齐方式 | 不可以 |

归档脚本只认 `receipts/run.receipt.json` 这一条正式路径。`candidates/` 与 `evidence-gaps/` 是任务产物，
不参与 manifest 的必填校验，但必须在 `FINAL_RECEIPT.open_items[]` 里逐条点名，不能静默丢弃。

## 4. 事件流与 stage 索引

不改 schema 的关联方式是在任务目录内加两个纯文本索引：

```text
<tasks-id>/receipts/events/gates-<YYYYMMDD>.jsonl   # 一行一个门禁事件
<tasks-id>/receipts/stage-index.json                # stage → 事件范围与产物
```

`gates-<YYYYMMDD>.jsonl` 按天切分，事件类型固定为 `EXECUTION_CHECK`、`PROGRESS_5M`、
`STAGE_FINISHED`、`BLOCKED`、`FINAL_RECEIPT`（整合规则 §5）。字段与 `ark.run-state.v1` 一致，
时间一律北京时间、不带时区标记。

`stage-index.json` 是索引不是契约，字段可以增补；最小形态：

```json
{
  "run_id": "20261110-120000_tcl-wake",
  "stages": [
    {
      "stage": 15,
      "name": "真机回归",
      "events": "receipts/events/gates-20261110.jsonl",
      "event_ids": ["ev-0007", "ev-0012"],
      "artifacts": [{"path": "result/rounds.csv", "sha256": "<64 位小写 hex>"}],
      "receipt_run_ids": ["20261110-120000_tcl-wake"],
      "rollback": "receipts/rollback-15-20261110-183000.json"
    }
  ]
}
```

索引只写路径与哈希，不复制证据字节。它与回执一碰就能交叉复核：回执的 `evidence_sha256[]` 应当
覆盖对应 stage 的全部 `artifacts[].sha256`；对不上就是证据缺口，不是索引笔误。

## 5. `FINAL_RECEIPT` 之前必须齐的材料

`FINAL_RECEIPT` 的字段见整合规则 §5.5。归档前逐项核对，缺一项就不算最终回执：

| 项 | 归档侧证据 |
|---|---|
| `receipt_path` / `receipt_sha256` | `receipts/run.receipt.json` 存在，且 `sha256sum` 与事件记录一致 |
| `manifest_path` | `<run_id>/manifest.json` 存在，`archive.manifest_sha256` 与文件一致 |
| `stage_summary[]` | 每个 stage 的 `STAGE_FINISHED` 都有 `gate_result=pass`，产物哈希可核 |
| `open_items[]` | 全部 `candidate` 与 `evidence-gap` 逐条列出，写明补齐方式 |
| `delivered_artifacts[]` | 交付到 `result/` 的文件清单，路径相对任务目录 |
| `result` | `pass` / `fail` / `blocked`，与回执 `result` 一致；不一致先修事实，不改事件 |

回执的 `result` 与 `STAGE_FINISHED` 的 `gate_result` 允许不同：前者是运行结论，后者是阶段判据。
出现「阶段全 pass、回执 fail」时在 `open_items[]` 说明原因，不要回头把阶段改成 fail 来凑一致。

## 6. 归档与回滚边界

- 归档只复制不移动，源数据不动；校验不通过整批进 `_quarantine`，正式目录不出现半成品。
- 归档永不删除既有证据：`manifest.v1`、回执、日志、`summary_final.json` 都是长期存证。
- 回滚单位是 **stage**，不是整个任务。回滚只追加 `receipts/rollback-<stage>-<stamp>.json`
  （`<stamp>` 用 `YYYYMMDD-HHMMSS` 文件名口径），记录原因、影响文件与恢复后校验结果；原证据与其
  `sha256` 保留。
- 发布审批与回滚审批是两次独立动作，批准发布不等于授权删除任何归档物（整合规则 §9）。
- 回滚后要重跑门禁：追加新的 `STAGE_FINISHED`（`gate_result` 按重跑结果），不覆盖旧事件。
