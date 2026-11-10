# 从旧交付物迁移到 ark-archive

> 本仓库是内部平台的公开仓库，只包含脚本、schema、测试和文档。**不含任何凭据、口令、私钥或内网密码**。迁移过程只做复制和整理，不搬运任何密钥材料。

本文件说明 `ark-archive` 与三份旧交付物之间的关系：哪些文件从哪里来、哪些行为有意改变、旧消费者会遇到什么、需要怎么迁移、以及如何回滚。

## 来源

三份旧交付物仍保留在各自任务目录，**本次迁移不删除、不移动、不改写它们**：

| 旧交付物 | 任务 | 原始位置 |
|---|---|---|
| `ark-archive` | NOAH-31 | `noah-31-a1151691ac7b/workdir/deliverables/` |
| `ark-receipt` | NOAH-29 | `noah-29-7085bcb1ff94/workdir/deliverables/` |
| `ark-prune` | NOAH-31 | `noah-31-a1151691ac7b/workdir/deliverables/` |

旧仓库的 `main` 分支保持原样，不做任何改写。本仓库是新的规范入口；旧仓库在迁移完成后用 tag 冻结，并以归档提案的形式收尾，不删除历史。

## 文件映射

“源行数”来自旧交付物的原始文件（只读统计）。“新行数”为本仓库当前实现，标注“新增”的是旧交付物中没有对应文件的文件。

| 新路径 | 原始来源路径 | 源行数 | 新行数 | 说明 |
|---|---|---|---|---|
| `bin/ark-archive.sh` | NOAH-31 `deliverables/ark-archive.sh` | 280 | 见仓库 | 迁入，改为调用共享时间库与 `lib/remote-verify.sh` |
| `bin/ark-archive.ps1` | NOAH-31 `deliverables/ark-archive.ps1` | 286 | 见仓库 | 迁入，行为对齐 bash 入口 |
| `bin/ark_receipt.py` | NOAH-29 `deliverables/ark_receipt.py` | 312 | 418 | 迁入并扩展：共享时间库、`raw_*`、`--legacy-rfc3339` |
| `bin/ark-receipt.sh` | NOAH-29 `deliverables/ark-receipt.sh` | 137 | 见仓库 | 迁入，作为回执的 Linux 入口 |
| `bin/ark-receipt.ps1` | NOAH-29 `deliverables/ark-receipt.ps1` | 163 | 见仓库 | 迁入，作为回执的 Windows 入口 |
| `bin/ark-prune.sh` | NOAH-31 `deliverables/ark-prune.sh` | 81 | 见仓库 | 迁入，保留策略不变，白名单清理 |
| `bin/ark-prune.ps1` | 无 | 0 | 新增 | PowerShell 清理入口，此前没有对等实现 |
| `lib/ark_time.py` | 无 | 0 | 251 | 新增，北京时间无时区契约的唯一实现（NOAH-43） |
| `lib/ark-time.sh` | 无 | 0 | 89 | 新增，`ark_time.py` 的 bash 薄封装 |
| `lib/ark-time.ps1` | 无 | 0 | 94 | 新增，`ark_time.py` 的 PowerShell 薄封装 |
| `lib/ark_common.py` | 无 | 0 | 新增 | 新增，路径常量、退出码、共享小工具 |
| `lib/remote-verify.sh` | 从 NOAH-31 两份归档脚本内嵌的 `ark-verify-remote.sh` 抽出 | 内嵌重复 | 新增 | 去重，bash 与 PowerShell 入口共用同一份校验逻辑 |
| `schemas/manifest.v1.json` | 由旧 manifest 结构固化 | 无 | 新增 | 新增 JSON Schema |
| `schemas/receipt.v1.json` | 由 `run.receipt.json` 结构固化（参考 NOAH-29 的 146 行样例） | 无 | 新增 | 新增 JSON Schema |
| `tests/` | 无 | 0 | 新增 | 新增单元测试、端到端夹具、`run-all.sh` |
| `tools/secret-scan.sh` | 无 | 0 | 新增 | 新增，扫描误提交的凭据 |
| `docs/time-contract.md` | 无 | 0 | 新增 | 新增，时间契约 |
| `docs/archive-flow.md` | 无 | 0 | 新增 | 新增，归档流程 |
| `docs/manifest.md`、`docs/receipt.md`、`docs/retention.md` | 无 | 0 | 新增 | 新增，字段与策略说明 |

## 行为变更

以下都是**有意为之**的变更，不是回归。

| 项 | 旧行为 | 新行为 | 影响面 |
|---|---|---|---|
| 用户可见时间格式 | RFC3339，带 `T` 与 `Z`（UTC）或 `+08:00` | 北京时间 `YYYY-MM-DD HH:MM:SS`，无 `T`、无 `Z`、无偏移 | 所有 manifest、回执、日志里的时间字符串 |
| 原始时间来源 | 无专门字段，原始时间被直接改写或丢弃 | 规范化结果进 `started_at` / `ended_at`，原值保留在 `raw_started_at` / `raw_ended_at` | manifest 消费方、排查流程 |
| 暂存目录结构 | bash 平铺上传，PowerShell 多套一层源目录 basename，两端不一致 | 两端统一为平铺：manifest 与文件同层 | 远端校验脚本的入参、人工排查 |
| 远端校验脚本 | 两份归档脚本各自内嵌一份 `ark-verify-remote.sh` | 抽出为 `lib/remote-verify.sh`，两端共用 | 维护成本、校验一致性 |
| Windows 清理 | 只有 `ark-prune.sh` | 新增 `bin/ark-prune.ps1`，参数与行为对齐 bash | Windows 节点可以在本机执行清理 |
| 退出码契约 | 各脚本各自定义，含义不完全一致 | 统一语义：成功、参数或输入错误、哈希不符、传输失败、依赖缺失分别可区分，具体数值以各脚本头注释为准 | 调用方脚本、调度器 |
| 旧消费者兼容 | 无兼容开关 | `--legacy-rfc3339` 显式开启时输出旧版 RFC3339（`+08:00`），默认关闭；`--tz-offset` 已废弃并被忽略 | 尚未升级的 `ark-kb` |

## 兼容性

### 会坏的地方

- **严格解析 RFC3339 的旧消费者**：例如用 `datetime.fromisoformat` 之后强转 UTC、或正则要求 `T` 的解析器，会把 `2026-11-10 12:09:56` 判为非法。这是时间契约变更的直接后果。
- **依赖旧路径的调用**：仍写死 `deliverables/ark-archive.sh` 等旧路径的脚本不会自动切到新仓库。旧路径本身仍然可用，但不会获得新功能。
- **传 `--tz-offset` 的调用**：旧参数被忽略并打印警告，输出不再按传入偏移调整。依赖该参数的调用需要改造。
- **依赖旧退出码含义的调度**：退出码语义已经统一，原来按数值分支的逻辑需要复核。

### 旧消费者迁移步骤

1. **先升级解析**：把解析用户可见时间的地方改成接受 `YYYY-MM-DD HH:MM:SS`。可以先用 `ark_time.audit` / `Get-ArkTimeAudit` 做自检，确认输入合规。
2. **处理原始时间**：如果旧逻辑读取 `started_at` 并假设它是 UTC，改为直接按北京时间使用；需要原始来源时改读 `raw_started_at` / `raw_ended_at`。
3. **过渡期兼容**：在 `ark-kb` 尚未升级完成前，可以在生成回执时显式加 `--legacy-rfc3339`，让它继续拿到旧形态。该开关是临时手段，消费者升级后必须去掉。
4. **切换调用路径**：把调用从旧 `deliverables/` 路径切到本仓库的 `bin/` 入口。参数名保持兼容：bash 侧原有长参数不变，PowerShell 侧原有 `-PascalCase` 参数不变。
5. **复核退出码**：按新的统一语义调整调度器的成功/失败判断。
6. **验证一次完整链路**：归档 -> 回执 -> 清理 dry-run，确认每一步输出都符合时间契约。

## 回滚

回滚成本很低，因为迁移只增加了新仓库，没有破坏旧的东西。

- **旧交付物仍在原位**：NOAH-31 与 NOAH-29 的 `deliverables/` 目录、旧仓库的 `main` 都没有被删除或改写。
- **回滚方式**：继续使用旧脚本，把集成点或 tag 重新指回旧交付物即可。旧脚本的行为与迁移前完全一致。
- **数据不受影响**：存储侧结果、回执、隔离区都由旧脚本和新脚本写入同一套布局，回滚不涉及数据迁移。
- **本仓库可以就地停用**：如果决定不继续推进，直接停用本仓库即可，不产生孤儿数据。

回滚不需要恢复任何备份，因为迁移过程没有执行删除操作。
