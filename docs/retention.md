# 归档保留策略（ark-prune）

本文件说明 `/srv/storage/ark/results/<node>/<project>/<run_id>/` 下各类证据的保留规则，
以及 `bin/ark-prune.sh`（Linux）与 `bin/ark-prune.ps1`（Windows）的用法。

## 一、保留策略表

策略为已确认的「方案 B」，数字不可更改：

| 路径 / 文件 | 内容 | 保留期 | 说明 |
|---|---|---|---|
| `summary_final.json`、`summary_final.*` | 运行摘要 | **永久** | 验收与复盘依据，永不清理 |
| `rounds.csv`、`manifest.json`、`receipt*` 等 | 证据 / 回执 / 清单 | **永久** | 审计链，永不清理 |
| `*/serial_logs/*` | 串口日志 | **30 天** | 体积最大、可重新采集 |
| `*/tool.log` | 工具日志 | **90 天** | 排障用，保留更久 |

「N 天」的判定为文件 mtime 早于当前时间 N 天（与 `find -mtime +N` 一致）。

## 二、白名单及其理由

允许被删除的**只有**两类普通文件：

- `*/serial_logs/*`：任意层级 `serial_logs` 目录下的文件；
- `*/tool.log`：任意层级、文件名恰为 `tool.log` 的文件。

任何其它文件、目录、符号链接都不在清理范围内。

这样设计的原因：

1. **证据不可再生**。`summary_final.json`、`manifest.json`、回执一旦误删，验收与审计链就断了，
   而串口日志和工具日志都可以重新采集。把删除面收缩到两个可再生模式，是最后一道保险。
2. **防止路径计算错误放大成事故**。脚本里不做「删掉某个 run 目录下的旧文件」这种整体操作，
   而是先列出具体文件、再逐个删除。即使白名单匹配逻辑写错，也不会波及证据文件。
3. **白名单是可审计的常量**。任何新增可清理类型都必须改代码、评审、更新本文档，
   而不是靠一个通配符在运行时临时决定。

脚本实现上另有两道约束：只在 `--root` 内匹配；只匹配普通文件（`find -type f` / PowerShell
显式跳过重解析点），不跟随符号链接；删除时逐个 `rm` / `Remove-Item` 白名单内的具体路径，
**绝不对计算出来的父目录执行 `rm -rf`**。

## 三、预演优先（dry-run first）

两个脚本**默认都是预演**，不删除任何东西。预演会打印：

- 根目录；
- 生效的保留天数；
- 候选文件数量与可释放字节数（含 MiB 换算）；
- 每个候选的字节数、契约格式 mtime（北京时间 `YYYY-MM-DD HH:MM:SS`）、完整路径。

确认清单符合预期后，再加 `--apply`（Windows 为 `-Apply`）。不带 `--yes` / `-Yes` 时会要求
在 stdin 输入字面量 `yes` 才会继续；输入其它内容即中止。脚本**没有**跳过确认的 `--force`。

## 四、命令

### Linux

```bash
# 1) 预演：只看候选，不删除
./bin/ark-prune.sh --root /srv/storage/ark/results

# 2) 交互确认后删除
./bin/ark-prune.sh --root /srv/storage/ark/results --apply

# 3) cron / 无人值守（跳过交互确认）
./bin/ark-prune.sh --root /srv/storage/ark/results --apply --yes

# 自定义保留天数（仍建议先预演）
./bin/ark-prune.sh --root /srv/storage/ark/results --serial-days 30 --tool-days 90
```

### Windows（PowerShell 5.1+）

```powershell
# 1) 预演
.\bin\ark-prune.ps1 -Root 'Z:\ark\results'

# 2) 交互确认后删除
.\bin\ark-prune.ps1 -Root 'Z:\ark\results' -Apply

# 3) 无人值守
.\bin\ark-prune.ps1 -Root 'Z:\ark\results' -Apply -Yes

# 自定义保留天数
.\bin\ark-prune.ps1 -Root 'Z:\ark\results' -SerialDays 30 -ToolDays 90
```

`-Root` 需指向 Windows 可见的同一份存储（映射盘或共享路径）。两个脚本语义完全一致：
同样的白名单、同样的默认天数、同样的预演默认值与输出格式。

## 五、退出码

| 退出码 | 含义 |
|---|---|
| `0` | 成功，包括「没有可清理的文件」 |
| `1` | 用户在确认提示处输入的不是 `yes`，已中止 |
| `2` | 用法 / 参数错误：缺少或非法 `--root` / `-Root`、天数不是正整数、或在过宽的根目录上运行 |
| `5` | 根目录不存在，或不是目录 |

为防止误操作，脚本拒绝在 `/`、`/srv`、`/srv/storage`、`/srv/storage/ark` 这些过宽的根目录上
运行（先解析符号链接再判断），命中即以退出码 `2` 中止。根目录检查在下标阶段完成，
`--root` 必须显式给出，不存在默认值。

## 六、警告：白名单之外永不触碰

**白名单之外的任何文件都不会被本工具删除，这是设计使然，不是遗漏。**

如果确实需要清理 `summary_final.json`、`manifest.json`、回执或整个 run 目录，
必须走**单独的、经过批准的操作流程**：先列清单与影响范围、取得审批、备份/记录路径，
再执行一次性人工操作。不要通过修改本脚本的通配符、也不要手工把白名单目录外的路径
塞进候选列表来绕过这一约束。
