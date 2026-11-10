# Changelog

本文件记录 `ark-archive` 的重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [Unreleased]

## [1.0.0] - 2026-11-10

首个统一版本。把此前分散的 `ark-archive`（NOAH-31）、`ark-receipt`（NOAH-29）、`ark-prune`（NOAH-31）收拢为一个规范仓库。

### Added

- 北京时间无时区时间契约（NOAH-43）：统一实现 `lib/ark_time.py`，以及 `lib/ark-time.sh`、`lib/ark-time.ps1` 两个薄封装。用户可见时间格式为 `YYYY-MM-DD HH:MM:SS`，文件名时间戳为 `YYYYMMDD_HHMMSS`。
- manifest 新增可选字段 `raw_started_at`、`raw_ended_at`，用于保留原始来源时间，不污染用户可见字段。
- 新增 `lib/ark_common.py`，集中路径常量、退出码与共享小工具。
- 新增 `lib/remote-verify.sh`，把原先内嵌在归档脚本里的远端校验逻辑抽出，bash 与 PowerShell 入口共用。
- 新增 `bin/ark-prune.ps1`，为 Windows 补齐按保留策略清理的入口。
- 新增 `schemas/manifest.v1.json`、`schemas/receipt.v1.json`，固化 v1 数据结构。
- 新增 `tests/`，包含单元测试、端到端夹具与 `run-all.sh`。
- 新增 `tools/secret-scan.sh`，扫描误提交的凭据。
- 新增 `docs/time-contract.md`、`docs/archive-flow.md`、`docs/manifest.md`、`docs/receipt.md`、`docs/retention.md`。
- 新增 `--legacy-rfc3339` 兼容开关，显式开启时为未迁移的 `ark-kb` 输出旧版 RFC3339 时间。

### Changed

- 所有用户可见时间从 UTC RFC3339（带 `T` / `Z`）改为北京时间契约格式，不再出现 `T`、`Z`、时区偏移或 `UTC` 字样。
- 归档暂存目录结构统一：Linux 与 Windows 都以暂存目录为内容根，manifest 与文件同层，不再多套一层源目录名。
- 回执生成改为只从共享时间库取时间，`bin/ark_receipt.py` 自身不再拼接时间字符串。
- 退出码语义统一，便于调度器区分参数错误、哈希不符、传输失败和依赖缺失。
- `--tz-offset` 参数标记为废弃，传入会被忽略并打印警告。

### Fixed

- 修复 bash 与 PowerShell 归档入口在远端校验入参上不一致的问题（暂存嵌套差异）。
- 修复远端校验脚本两份副本可能漂移的问题，改为单一来源。
- 修复旧流程在同名 run 重复归档时直接覆盖、无法追溯旧副本的问题：旧副本现在移入 `_quarantine` 并带 `-replaced` 后缀。
- 修复回执中的时间在不同平台格式不一致的问题。
