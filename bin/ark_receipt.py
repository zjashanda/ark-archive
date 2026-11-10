#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ark_receipt.py —— 由归档 manifest 生成 run.receipt.v1 回执。

设计要点
--------
1. 回执事实来源是**归档后**的 manifest.json（其 sha256 已在存储服务器上重算校验过），
   不是跑测机上的临时目录，所以 evidence_dir 一定写成存储路径。
2. 只读本地文件，不做网络访问；取/传由 ark-receipt.sh、ark-receipt.ps1 负责。
3. 输出除 schema 必填字段外，额外带 `evidence_files`（path+sha256+bytes），
   供 ark-kb 在「证据不在本机」时仍然登记每个文件的存储路径。
4. **时间契约（NOAH-43）**：所有用户可见时间（started_at / ended_at /
   archive.archived_at，以及 notes 中引用的归档时间）一律是北京时间
   `YYYY-MM-DD HH:MM:SS`，没有 `T`、没有 `Z`、没有 `+08:00`。
   格式化只走共享库 `lib/ark_time.py`，本文件不自己拼时间。
   `--legacy-rfc3339` 是唯一例外：显式开启时输出旧版 `+08:00` RFC3339，
   供尚未迁移的 ark-kb 消费，默认关闭。
5. 单文件、无第三方依赖，Python 3.6+ 可运行（Windows 上用 `py -3` 调用）。

用法
----
    ark_receipt.py --manifest <dir>/manifest.json --summary <dir>/summary_final.json \
        --node win009 --project tcl-r5 [--run-id 20261102_090644_wake_recognition] \
        [--task "…"] [--skill lstest] [--skill-version 0.1] [--firmware …] \
        [--platform …] [--confidence high|medium|low] \
        [--lessons lessons.json] [--bugs bugs.json] [--tags a,b] \
        [--storage-root /srv/storage/ark] [--evidence-dir …] \
        [--out run.receipt.json] [--no-local-verify] [--dry-run] \
        [--legacy-rfc3339] [--tz-offset（已废弃，仅兼容入参）]

输出（普通模式，stdout 机器可读行）
-----------------------------------
    VERIFY=local_files=<已校验>/<总条目> mismatches=<不匹配数>
    RECEIPT=<回执落地路径>
    RECEIPT_SHA256=<回执文件的 sha256>
    EVIDENCE_DIR=<证据存储目录>
    EVIDENCE_FILES=<文件数> BYTES=<总字节>
    RESULT=<pass|fail|blocked|invalid|needs_review> CONFIDENCE=<high|medium|low>

`--dry-run` 时 stdout 只输出回执 JSON（便于直接管道），VERIFY=/RESULT=/落盘提示
改走 stderr。

退出码
------
    0  成功（含 --dry-run）
    2  输入/校验失败：参数缺失、manifest 条目非法、时间无法解析、result 无法映射
    3  本地文件哈希与 manifest 不一致（拒绝生成回执）
    5  缺少共享时间库 lib/ark_time.py 或运行环境依赖
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

SCHEMA = "run.receipt.v1"
DEFAULT_STORAGE_ROOT = "/srv/storage/ark"
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
RESULT_MAP = {
    "PASS": "pass",
    "FAIL": "fail",
    "BLOCKED": "blocked",
    "INVALID": "invalid",
    "ERROR": "needs_review",
    "NEEDS_REVIEW": "needs_review",
}

# ---------------------------------------------------------------------------
# 共享时间库：lib/ark_time.py 是北京时间无时区契约的唯一实现。
# 仓库可能被 checkout 到任意路径，因此按本文件位置推 ../lib 并注入 sys.path。
# 库缺失时给出中文错误并以 5 退出——绝不让 ImportError 的英文栈糊到用户脸上。
# ---------------------------------------------------------------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB_DIR = os.path.normpath(os.path.join(_HERE, os.pardir, "lib"))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
try:
    import ark_time
except Exception as _exc:  # 缺文件、语法错、权限问题都按「依赖缺失」处理
    sys.stderr.write(
        "ERROR: 缺少共享时间库 %s/ark_time.py，无法生成回执：%s\n" % (_LIB_DIR, _exc)
    )
    raise SystemExit(5)


def die(msg, code=2):
    """以统一格式报错并退出；默认 2=输入/校验失败。"""
    sys.stderr.write("ERROR: %s\n" % msg)
    raise SystemExit(code)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        die("找不到文件：%s" % path)
    except json.JSONDecodeError as exc:
        die("JSON 解析失败：%s：%s" % (path, exc))


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def time_text(value, field, legacy=False):
    """把 manifest 时间统一成契约格式（或 legacy 旧格式）。

    唯一的格式化入口，全部委托给 ark_time，本文件不再自己拼 `T` / 偏移。
    """
    try:
        if legacy:
            return ark_time.legacy_rfc3339(value)
        return ark_time.to_text(value)
    except ark_time.TimeContractError as exc:
        die("%s 不是合法时间：%r（%s）" % (field, value, exc))


def build_evidence(manifest, evidence_dir):
    """校验 manifest 条目并展开 evidence 三元组；条目非法即 exit 2。"""
    files = manifest.get("files") or []
    if not isinstance(files, list) or not files:
        die("manifest.files 为空，无法生成 evidence_sha256")
    hashes = []
    evidence_files = []
    total_bytes = 0
    for item in files:
        if not isinstance(item, dict):
            die("manifest 条目非法（不是对象）：%r" % (item,))
        rel = str(item.get("path") or "").replace("\\", "/").strip().lstrip("./")
        sha = str(item.get("sha256") or "").strip().lower()
        try:
            size = int(item.get("bytes") or 0)
        except (TypeError, ValueError):
            die("manifest 条目 bytes 非法：%r" % (item,))
        if not rel or not SHA_RE.match(sha):
            die("manifest 条目非法（path/sha256）：%r" % (item,))
        hashes.append(sha)
        evidence_files.append({"path": rel, "sha256": sha, "bytes": size})
        total_bytes += size
    if not hashes:
        die("manifest.files 中没有可用条目")
    return {
        "evidence_dir": evidence_dir.rstrip("/"),
        "evidence_sha256": hashes,
        "evidence_files": evidence_files,
        "total_bytes": total_bytes,
    }


def build_totals(summary, manifest_files, total_bytes):
    normal = summary.get("normal_window") or {}
    boundary = summary.get("boundary_window") or {}
    totals = {
        "rounds": summary.get("completed_rounds", 0),
        "target_rounds": summary.get("target_rounds", 0),
        "duration_minutes": summary.get("duration_minutes", 0),
        "recognized": normal.get("recognized", 0),
        "failed": normal.get("failed", 0),
        "recognition_rate": normal.get("recognition_rate", None),
        "boundary_unexpected": boundary.get("unexpected_results", 0),
        "serial_error_kinds": len(summary.get("serial_errors") or {}),
        "warning_markers": sum((summary.get("warning_marker_round_counts") or {}).values()),
        "archived_files": manifest_files,
        "archived_bytes": total_bytes,
    }
    if summary.get("status_counts"):
        totals["status_counts"] = summary["status_counts"]
    return totals


def build_failures(summary):
    failures = []
    normal = summary.get("normal_window") or {}
    boundary = summary.get("boundary_window") or {}
    if int(normal.get("failed") or 0) > 0:
        failures.append(
            {
                "name": "唤醒/命令词识别失败",
                "reason": "正常窗口 %s 轮未识别（识别率 %s）"
                % (normal.get("failed"), normal.get("recognition_rate")),
                "attribution": "device",
                "evidence": ["summary_final.json"],
            }
        )
    if int(boundary.get("unexpected_results") or 0) > 0:
        failures.append(
            {
                "name": "边界窗口出现非预期结果",
                "reason": "unexpected_results=%s" % boundary.get("unexpected_results"),
                "attribution": "corpus",
                "evidence": ["summary_final.json"],
            }
        )
    if str(summary.get("error") or "").strip():
        failures.append(
            {
                "name": "运行期错误",
                "reason": str(summary["error"]).strip()[:500],
                "attribution": "tool",
                "evidence": ["errors.log", "summary_final.json"],
            }
        )
    return failures


def main(argv=None):
    ap = argparse.ArgumentParser(description="由归档 manifest 生成 run.receipt.v1")
    ap.add_argument("--manifest", required=True, help="归档目录下的 manifest.json")
    ap.add_argument("--summary", default=None, help="归档目录下的 summary_final.json")
    ap.add_argument("--node", default=None, help="节点名（缺省取 manifest.node）")
    ap.add_argument("--project", default=None, help="项目名（缺省取 manifest.project）")
    ap.add_argument("--run-id", default=None, help="run_id（缺省取 manifest.run_id）")
    ap.add_argument(
        "--storage-root", default=DEFAULT_STORAGE_ROOT, help="存储根，默认 /srv/storage/ark"
    )
    ap.add_argument(
        "--evidence-dir", default=None, help="显式指定 evidence_dir（默认自动拼存储路径）"
    )
    ap.add_argument("--task", default=None, help="任务描述，进 KB 标题/claim")
    ap.add_argument("--skill", default="lstest", help="产出该结果的 skill")
    ap.add_argument("--skill-version", default="unknown", help="skill 版本")
    ap.add_argument("--firmware", default=None, help="固件标识")
    ap.add_argument(
        "--platform", default=None, help="平台描述，默认 '<node> (<manifest.device>)'"
    )
    ap.add_argument("--confidence", default=None, choices=["high", "medium", "low"])
    ap.add_argument("--lessons", default=None, help="lessons JSON 文件（数组）")
    ap.add_argument("--bugs", default=None, help="bugs_found JSON 文件（数组）")
    ap.add_argument("--tags", default=None, help="逗号分隔附加标签")
    ap.add_argument(
        "--legacy-rfc3339",
        action="store_true",
        help="输出旧版 RFC3339（+08:00）时间，仅供未迁移的 ark-kb；默认关闭",
    )
    ap.add_argument(
        "--tz-offset",
        default=None,
        help="已废弃：旧版补偏移参数，现在被忽略（时间契约固定北京时间无时区）",
    )
    ap.add_argument("--out", default=None, help="回执输出路径（缺省与 manifest 同目录）")
    ap.add_argument("--no-local-verify", action="store_true", help="跳过本地哈希复核")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不落盘")
    args = ap.parse_args(argv)

    if args.tz_offset is not None:
        sys.stderr.write(
            "WARN: --tz-offset 已废弃（NOAH-43 北京时间无时区契约），参数被忽略\n"
        )

    manifest_path = Path(args.manifest).expanduser()
    manifest = load_json(manifest_path)
    base_dir = manifest_path.parent
    summary_path = (
        Path(args.summary).expanduser() if args.summary else (base_dir / "summary_final.json")
    )
    summary = load_json(summary_path) if summary_path.is_file() else {}

    run_id = (args.run_id or manifest.get("run_id") or "").strip()
    node = (args.node or manifest.get("node") or "").strip()
    project = (args.project or manifest.get("project") or "").strip()
    if not run_id or not node or not project:
        die("run_id / node / project 必须可知（manifest 或命令行给出）")

    evidence_dir = args.evidence_dir or "%s/results/%s/%s/%s" % (
        args.storage_root.rstrip("/"),
        node,
        project,
        run_id,
    )

    # 先校验 manifest 条目（exit 2 优先），再复核本地哈希（exit 3）
    evidence = build_evidence(manifest, evidence_dir)

    verify_line = "VERIFY=skipped"
    if not args.no_local_verify:
        checked = 0
        mismatched = 0
        for item in manifest.get("files") or []:
            rel = str(item.get("path") or "").replace("\\", "/").strip().lstrip("./")
            local = base_dir / rel
            if not rel or not local.is_file():
                continue
            checked += 1
            if sha256_file(local) != str(item.get("sha256") or "").lower():
                mismatched += 1
        total_entries = len(manifest.get("files") or [])
        verify_line = "VERIFY=local_files=%d/%d mismatches=%d" % (
            checked,
            total_entries,
            mismatched,
        )
        if mismatched:
            sys.stdout.write(verify_line + "\n")
            die("本地文件与 manifest 哈希不一致 %d 个，拒绝生成回执" % mismatched, 3)

    totals = build_totals(summary, len(evidence["evidence_files"]), evidence["total_bytes"])

    raw_result = str(manifest.get("result") or "").strip().upper()
    result = RESULT_MAP.get(raw_result)
    if result is None:
        die(
            "manifest.result=%r 无法映射到 pass/fail/blocked/invalid/needs_review"
            % raw_result
        )

    # ---- 时间：唯一出口是 ark_time，默认契约格式，--legacy-rfc3339 才用旧格式 ----
    legacy = bool(args.legacy_rfc3339)
    started = time_text(manifest.get("started_at"), "manifest.started_at", legacy)
    archived_raw = manifest.get("archived_at") or manifest.get("ended_at")
    ended = time_text(
        manifest.get("ended_at") or archived_raw, "manifest.ended_at", legacy
    )
    archived = time_text(archived_raw, "manifest.archived_at", legacy)

    # notes 也属于用户可见文本，绝不透传原始 Z/+08:00 时间：固定用契约格式。
    archived_for_notes = time_text(archived_raw, "manifest.archived_at", False)

    task = (args.task or "%s 压测归档（%s）" % (project, run_id)).strip()
    platform = args.platform or "%s (%s)" % (
        node,
        manifest.get("device") or "unknown",
    )

    lessons = load_json(Path(args.lessons).expanduser()) if args.lessons else []
    bugs = load_json(Path(args.bugs).expanduser()) if args.bugs else []
    if not isinstance(lessons, list) or not isinstance(bugs, list):
        die("--lessons / --bugs 必须是 JSON 数组")

    if args.confidence:
        confidence = args.confidence
    elif result == "pass" and totals.get("rounds", 0) and totals.get("failed", 0) == 0:
        confidence = "high"
    else:
        confidence = "medium"

    tags = ["archive", node, project, result]
    if args.tags:
        tags += [part.strip() for part in args.tags.split(",") if part.strip()]

    receipt = {
        "schema": SCHEMA,
        "run_id": run_id,
        "task": task,
        "skill": args.skill,
        "skill_version": args.skill_version,
        "scope": {
            "device": manifest.get("device"),
            "project": project,
            "firmware": args.firmware,
            "platform": platform,
        },
        "result": result,
        "totals": totals,
        "failures": build_failures(summary),
        "bugs_found": bugs,
        "evidence_dir": evidence["evidence_dir"],
        "evidence_sha256": evidence["evidence_sha256"],
        "evidence_files": evidence["evidence_files"],
        "lessons": lessons,
        "confidence": confidence,
        "started_at": started,
        "ended_at": ended,
        "notes": (
            "回执由归档 manifest 自动生成：node=%s project=%s archived_at=%s "
            "files=%d bytes=%d；源目录 %s"
            % (
                node,
                project,
                archived_for_notes,
                len(evidence["evidence_files"]),
                evidence["total_bytes"],
                manifest.get("source_dir") or "",
            )
        ),
        "tags": sorted(set(tags)),
        "archive": {
            "node": node,
            "project": project,
            "storage_root": args.storage_root.rstrip("/"),
            "archived_at": archived,
            "source_dir": manifest.get("source_dir"),
            "manifest_sha256": sha256_file(manifest_path),
        },
    }

    payload = json.dumps(receipt, ensure_ascii=False, indent=2) + "\n"
    out_path = Path(args.out).expanduser() if args.out else (base_dir / "run.receipt.json")

    if args.dry_run:
        # stdout 保持纯 JSON，机器可读行改走 stderr，方便直接管道消费
        sys.stderr.write(verify_line + "\n")
        sys.stderr.write("DRY-RUN: receipt 未落盘（目标 %s）\n" % out_path)
        sys.stderr.write("RESULT=%s CONFIDENCE=%s\n" % (result, confidence))
        sys.stdout.write(payload)
        return 0

    out_path.write_text(payload, encoding="utf-8")
    print(verify_line)
    print("RECEIPT=%s" % out_path)
    print("RECEIPT_SHA256=%s" % sha256_file(out_path))
    print("EVIDENCE_DIR=%s" % evidence["evidence_dir"])
    print(
        "EVIDENCE_FILES=%d BYTES=%d"
        % (len(evidence["evidence_files"]), evidence["total_bytes"])
    )
    print("RESULT=%s CONFIDENCE=%s" % (result, confidence))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
