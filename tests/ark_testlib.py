# -*- coding: utf-8 -*-
"""测试公共工具：仓库定位、子进程、时间契约断言、JSON 提取。

本文件不属于测试用例（文件名不是 test*.py），只被各测试模块导入。
全部仅用标准库，不联网、不 ssh、不读写仓库外路径（临时目录除外）。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_DIR = os.path.join(REPO_ROOT, "bin")
LIB_DIR = os.path.join(REPO_ROOT, "lib")
TOOLS_DIR = os.path.join(REPO_ROOT, "tools")
FIXTURES_DIR = os.path.join(REPO_ROOT, "tests", "fixtures")

#: 用户可见时间契约：YYYY-MM-DD HH:MM:SS
CONTRACT_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
#: 文件名时间戳契约：YYYYMMDD_HHMMSS
STAMP_RE = re.compile(r"^\d{8}_\d{6}$")
#: 契约里禁止出现的片段
FORBIDDEN_TIME_TOKENS = ("T", "Z", "+08:00", "UTC", "GMT")


def python_exe() -> str:
    """返回当前解释器路径，保证子进程与测试用同一个 python。"""
    return sys.executable or "python3"


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(args, cwd=REPO_ROOT, env=None, timeout=120):
    """在受控环境下跑子进程，返回 CompletedProcess（text=True）。

    主动清掉 ARK_STORAGE_SSH_PASS，避免宿主环境变量把凭据带进测试。
    """
    merged = os.environ.copy()
    merged.pop("ARK_STORAGE_SSH_PASS", None)
    merged.setdefault("LC_ALL", "C.UTF-8")
    merged.setdefault("LANG", "C.UTF-8")
    if env:
        merged.update(env)
    return subprocess.run(
        args,
        cwd=cwd,
        env=merged,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def extract_json_object(text: str, predicate) -> dict:
    """从混合输出里找出第一个满足 predicate 的 JSON 对象。

    脚本可能先打印人类可读行再打印 JSON，因此不能直接 json.loads 整段。
    """
    decoder = json.JSONDecoder()
    index = text.find("{")
    while index != -1:
        try:
            obj, _end = decoder.raw_decode(text[index:])
        except ValueError:
            obj = None
        if isinstance(obj, dict) and predicate(obj):
            return obj
        index = text.find("{", index + 1)
    raise AssertionError("输出中找不到符合预期的 JSON 对象：\n" + text[:4000])


def extract_manifest(text: str) -> dict:
    """从 ark-archive.sh --dry-run 输出中提取清单 JSON。"""
    return extract_json_object(
        text, lambda obj: "run_id" in obj and "files" in obj and "project" in obj
    )


def extract_receipt(text: str) -> dict:
    """从 ark_receipt.py 输出中提取回执 JSON（按结构识别，schema 值另行断言）。"""
    return extract_json_object(
        text,
        lambda obj: "run_id" in obj
        and "evidence_sha256" in obj
        and "result" in obj
        and ("schema" in obj),
    )


def assert_contract_time(testcase, value, label: str) -> None:
    """断言 value 是契约时间，失败信息要能直接定位到字段。"""
    testcase.assertIsInstance(value, str, "%s 必须是字符串，实际 %r" % (label, value))
    testcase.assertRegex(
        value, CONTRACT_RE, "%s 不是契约格式 YYYY-MM-DD HH:MM:SS：%r" % (label, value)
    )
    for token in FORBIDDEN_TIME_TOKENS:
        testcase.assertNotIn(
            token, value, "%s 含违约片段 %r：%r" % (label, token, value)
        )


def skip_without(testcase, *paths) -> None:
    """脚本尚未落盘时跳过，并说明缺哪个文件（不伪造 bin/ 内容）。"""
    missing = [p for p in paths if not os.path.isfile(p)]
    if missing:
        testcase.skipTest("迁移脚本尚未落盘，跳过: " + ", ".join(missing))
