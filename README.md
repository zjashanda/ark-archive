# ark-archive

> 本仓库是内部平台的公开仓库，只包含脚本、schema、测试和文档。**不含任何凭据、口令、私钥或内网密码**。所有需要认证的场景都从运行环境读取密钥，仓库内不保存明文。

**版本**：`v1.0.0` · **状态**：稳定（stable）· **平台**：Linux（bash 4+、python3）与 Windows（PowerShell 5.1、`py -3`）

## 这是什么

`ark-archive` 是方舟结果归档流水线的唯一公开入口：把一次压测或任务的产出目录，可靠地归档到集中存储，并在归档前后用 SHA-256 校验每一个文件，任何不一致都进入隔离区而不是污染结果区；归档完成后可以生成结构化回执（receipt），并按保留策略清理过期的大体积日志。它把此前分散的三份交付物（`ark-archive` NOAH-31、`ark-receipt` NOAH-29、`ark-prune` NOAH-31）收拢到一处，共享同一套时间契约与远端校验实现。

设计目标只有三条：**不丢、不错、可追溯**。不丢，归档是先暂存再原子落位，旧副本进隔离区而不是被覆盖；不错，每个文件在远端重算哈希，和本地 manifest 逐条比对；可追溯，每次归档都有 manifest，每份回执都指向存储上的证据目录。

## 目录结构

```
lib/     ark_time.py  ark-time.sh  ark-time.ps1  ark_common.py  remote-verify.sh
bin/     ark-archive.sh  ark-archive.ps1  ark_receipt.py  ark-receipt.sh  ark-receipt.ps1  ark-prune.sh  ark-prune.ps1
schemas/ manifest.v1.json  receipt.v1.json
tests/   test_*.py  run-all.sh  fixtures/
tools/   secret-scan.sh  time_lint.py
docs/    time-contract.md  archive-flow.md  manifest.md  receipt.md  retention.md
```

- `lib/`：共享实现。`ark_time.py` 是时间契约的唯一实现，`ark-time.sh` / `ark-time.ps1` 只是薄封装；`remote-verify.sh` 是远端重算校验脚本，被归档入口共用。
- `bin/`：命令行入口。每个能力都有 Linux 与 Windows 两个入口。
- `schemas/`：`manifest.v1` 与 `receipt.v1` 的 JSON Schema。
- `tests/`：单元测试与端到端夹具，`run-all.sh` 一次跑完。
- `tools/`：仓库自检工具。`secret-scan.sh` 扫描是否误提交了凭据；`time_lint.py` 扫描时间契约违规（规则集与 `skillhub-sync`、`venusahisiburner` 同源）。
- `docs/`：时间契约、归档流程、manifest、receipt、保留策略的详细说明。

存储侧布局（`linux003` 等存储节点）：

```
/srv/storage/ark/
├── env/                                   # 环境变量真源与分发脚本
├── results/<node>/<project>/<run_id>/     # 归档结果，每个 run 一个目录
├── receipts/<node>/<project>/<run_id>/    # 对应的回执
├── artifacts/                             # 需要长期保留的产物
└── _quarantine/                           # 校验失败或被替换的副本
```

## 5 分钟上手

示例统一使用存储节点 `10.11.63.24`、用户 `administrator`、端口 `10027`。**口令只通过环境变量传入，不写进命令行、不写进脚本、不写进仓库。**

### Linux：归档

```bash
cd ark-archive

# 口令只进当前 shell 的环境变量
read -rsp '存储机 SSH 口令: ' ARK_STORAGE_SSH_PASS && export ARK_STORAGE_SSH_PASS

# 1) 先 dry-run：只打印目标路径、文件清单和 manifest 预览，不连远端
bash bin/ark-archive.sh \
  --source /data/runs/20261102_090644_wake_recognition \
  --project tcl-r5 --node win009 --device TCL-R5 \
  --host 10.11.63.24 --port 10027 --user administrator \
  --dry-run

# 2) 确认清单无误后真正归档
bash bin/ark-archive.sh \
  --source /data/runs/20261102_090644_wake_recognition \
  --project tcl-r5 --node win009 --device TCL-R5 \
  --host 10.11.63.24 --port 10027 --user administrator
```

### Windows：归档

```powershell
# 口令只进当前进程的环境变量
$env:ARK_STORAGE_SSH_PASS = Read-Host '存储机 SSH 口令'

# 1) 先 dry-run
.\bin\ark-archive.ps1 -SourceDir D:\runs\20261102_090644_wake_recognition `
  -Project tcl-r5 -Node win009 -Device TCL-R5 `
  -StorageHost 10.11.63.24 -StoragePort 10027 -StorageUser administrator -DryRun

# 2) 真正归档
.\bin\ark-archive.ps1 -SourceDir D:\runs\20261102_090644_wake_recognition `
  -Project tcl-r5 -Node win009 -Device TCL-R5 `
  -StorageHost 10.11.63.24 -StoragePort 10027 -StorageUser administrator
```

### Linux：生成回执

```bash
export ARK_STORAGE_HOST=10.11.63.24
export ARK_STORAGE_PORT=10027
export ARK_STORAGE_USER=administrator

# 生成回执并回传到 receipts/<node>/<project>/<run_id>/
bash bin/ark-receipt.sh \
  --node win009 --project tcl-r5 \
  --run-id 20261102_090644_wake_recognition \
  --storage-root /srv/storage/ark --upload
```

### Windows：生成回执

```powershell
.\bin\ark-receipt.ps1 -Node win009 -Project tcl-r5 `
  -RunId 20261102_090644_wake_recognition `
  -StorageHost 10.11.63.24 -StoragePort 10027 -StorageUser administrator -Upload
```

### Linux：按保留策略清理（默认 dry-run）

```bash
# 只列候选文件与可回收空间，不删除
bash bin/ark-prune.sh --root /srv/storage/ark/results

# 确认后真正删除
bash bin/ark-prune.sh --root /srv/storage/ark/results --apply
```

### Windows：按保留策略清理（默认 dry-run）

> 清理只作用于脚本所在机器上可见的结果目录（本地盘或已挂载的网络盘）。

```powershell
# 默认 dry-run，只列候选
.\bin\ark-prune.ps1 -Root Z:\ark\results

# 确认后真正删除
.\bin\ark-prune.ps1 -Root Z:\ark\results -Apply
```

## 时间契约（NOAH-43）

所有**用户可见**的时间都是北京时间，固定格式 `YYYY-MM-DD HH:MM:SS`，不带 `T`、不带 `Z`、不带任何时区偏移，也不出现 `UTC` 字样。文件名时间戳固定为 `YYYYMMDD-HHMMSS`（连字符）。历史归档目录可能仍是下划线形式，读取方用 `is_legacy_stamp()` 识别，**只读兼容、不迁移不改名**；新数据一律连字符。

| 场景 | 允许的写法 | 示例 |
|---|---|---|
| 用户可见时间（JSON、日志、报告） | `YYYY-MM-DD HH:MM:SS` | `2026-11-10 12:09:56` |
| 文件名时间戳 | `YYYYMMDD-HHMMSS` | `20261110-120956` |
| 原始来源时间 | 只保留在 `raw_*` 字段 | `raw_started_at`、`raw_ended_at` |
| 禁止 | `T` 分隔符、`Z` 后缀、时区偏移、`UTC` 字样 | 一律不允许 |

格式化只能调用 `lib/ark_time.py`（以及 `ark-time.sh` / `ark-time.ps1`），**任何 skill 或脚本都不得自己拼时间**。细节见 [docs/time-contract.md](docs/time-contract.md)。

时间契约门禁（2026-11-11 起：四段均 0 违规，退出码 0）：

```bash
for d in lib bin schemas docs; do
  python3 tools/time_lint.py --root "$d" --gate || exit 1
done
```

`tests/` 保存负例与历史回归数据（原始 `summary_final` 样本、`legacy_rfc3339()` 断言等），不纳入门禁，基线用 `python3 tools/time_lint.py --root tests --json` 单独记录。

## 安全设计

- **远端复核**：文件先上传到暂存目录，然后在存储节点上逐个重算 SHA-256，与本地 manifest 逐条比对，全部一致才落位。
- **隔离区**：哈希不一致时整个暂存目录移入 `_quarantine`，run 直接失败；同名 run 的旧副本被替换时也移入 `_quarantine` 并带 `-replaced` 后缀，不直接覆盖。
- **白名单清理**：保留策略只作用于 `serial_logs/`（30 天）和 `tool.log`（90 天），白名单外的文件永不删除。
- **默认 dry-run**：归档可以 `--dry-run` 先看计划；清理默认就是 dry-run，必须显式 `--apply` 才会删除。
- **仓库无凭据**：口令只从环境变量读取，脚本内只引用变量名；`tools/secret-scan.sh` 用于扫描是否误提交了密钥。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/time-contract.md](docs/time-contract.md) | 北京时间无时区契约、正反例、`raw_*` 溯源、`--legacy-rfc3339` 弃用路径、审计方法 |
| [docs/archive-flow.md](docs/archive-flow.md) | 归档流水线逐步说明、远端校验序列、失败与隔离、恢复方法 |
| [docs/manifest.md](docs/manifest.md) | `manifest.v1` 字段说明 |
| [docs/receipt.md](docs/receipt.md) | `receipt.v1` 字段说明 |
| [docs/retention.md](docs/retention.md) | 保留策略与清理白名单 |
| [MIGRATION.md](MIGRATION.md) | 从三份旧交付物迁移过来的文件映射、行为变更、兼容与回滚 |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更记录 |

---

版本 `v1.0.0`，发布于 2026-11-10。
