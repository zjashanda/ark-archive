#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ark_time —— 北京时间无时区时间契约（NOAH-43）的唯一实现。

契约
----
1. 所有**用户可见**的时间一律使用北京时间（Asia/Shanghai，UTC+8）。
2. 文本格式固定为 ``YYYY-MM-DD HH:MM:SS``，**禁止**出现 ``T``、``Z``、
   ``+08:00``、``UTC`` 或任何时区偏移后缀。
3. 文件名时间戳固定为 ``YYYYMMDD_HHMMSS``。
4. 原始来源时间（设备日志、summary_final.json 等）只能以 ``raw`` 前缀的
   字段保留，不得直接透传给用户。

设计约束
--------
* 使用固定 UTC+8 偏移而不是 zoneinfo，避免 Windows / 精简容器缺 tzdata。
  Asia/Shanghai 自 1991 年起无夏令时，固定偏移对全部历史与本项目数据等价。
* 本模块**没有第三方依赖**，Python 3.6+ 可运行（Windows 上由 ``py -3`` 调用）。
* 其它语言入口（bash / PowerShell）只做薄封装，格式化逻辑仍是这一套规则：
  ``lib/ark-time.sh``、``lib/ark-time.ps1``。

命令行
------
    python3 lib/ark_time.py now                 # 2026-11-10 12:09:56
    python3 lib/ark_time.py stamp               # 20261110_120956
    python3 lib/ark_time.py normalize "2026-11-09T02:54:39Z"
    python3 lib/ark_time.py check "2026-11-10 12:09:56"   # exit 0/1
    python3 lib/ark_time.py legacy "2026-11-10 12:09:56"  # 兼容旧消费者
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import sys

#: 用户可见时间格式（唯一允许的格式）
CONTRACT_FORMAT = "%Y-%m-%d %H:%M:%S"
#: 文件名时间戳格式
STAMP_FORMAT = "%Y%m%d_%H%M%S"
#: 北京时间固定偏移，避免 tzdata 依赖
BEIJING = _dt.timezone(_dt.timedelta(hours=8), "Asia/Shanghai")
#: 契约格式的严格校验
CONTRACT_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
#: 文件名时间戳的严格校验
STAMP_RE = re.compile(r"^\d{8}_\d{6}$")

# RFC3339 / ISO8601 的常见变体，统一由 _parse_text 处理
_ISO_RE = re.compile(
    r"^\s*(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?"
    r"\s*(Z|z|[+-]\d{2}:?\d{2})?\s*$"
)


class TimeContractError(ValueError):
    """输入无法解析，或输出会违反无时区契约。"""


def now():
    """当前北京时间（aware datetime，UTC+8）。"""
    return _dt.datetime.now(BEIJING).replace(microsecond=0)


def now_text():
    """当前北京时间，契约格式。"""
    return now().strftime(CONTRACT_FORMAT)


def now_stamp():
    """当前北京时间，文件名时间戳格式。"""
    return now().strftime(STAMP_FORMAT)


def _coerce(value):
    """把任意输入转成 aware datetime（北京时间）。"""
    if isinstance(value, _dt.datetime):
        if value.tzinfo is None:
            # 朴素时间视为北京时间——本项目所有数据源都是北京时间
            return value.replace(tzinfo=BEIJING).replace(microsecond=0)
        return value.astimezone(BEIJING).replace(microsecond=0)
    if isinstance(value, _dt.date):
        return _dt.datetime(value.year, value.month, value.day, tzinfo=BEIJING)
    if isinstance(value, bool):
        raise TimeContractError("bool 不是时间")
    if isinstance(value, (int, float)):
        return _dt.datetime.fromtimestamp(float(value), BEIJING).replace(microsecond=0)
    if value is None:
        raise TimeContractError("时间是 None")
    if not isinstance(value, str):
        raise TimeContractError("不支持的时间类型: %r" % type(value))

    text = value.strip()
    if not text:
        raise TimeContractError("时间是空字符串")
    # 纯数字字符串按 epoch 秒处理（10 位）或毫秒（13 位）
    if text.isdigit():
        num = int(text)
        if len(text) >= 13:
            num = num / 1000.0
        return _dt.datetime.fromtimestamp(num, BEIJING).replace(microsecond=0)

    m = _ISO_RE.match(text)
    if not m:
        raise TimeContractError("无法识别的时间格式: %s" % value)
    year, month, day, hour, minute = (int(m.group(i)) for i in range(1, 6))
    second = int(m.group(6) or 0)
    micro = int((m.group(7) or "0").ljust(6, "0"))
    suffix = m.group(8)
    if suffix in (None, ""):
        tzinfo = BEIJING
    elif suffix in ("Z", "z"):
        tzinfo = _dt.timezone.utc
    else:
        sign = 1 if suffix[0] == "+" else -1
        digits = suffix[1:].replace(":", "")
        offset = _dt.timedelta(hours=int(digits[:2]), minutes=int(digits[2:4]))
        tzinfo = _dt.timezone(sign * offset)
    try:
        parsed = _dt.datetime(year, month, day, hour, minute, second, micro, tzinfo)
    except ValueError as exc:
        raise TimeContractError("非法时间 %s: %s" % (value, exc))
    return parsed.astimezone(BEIJING).replace(microsecond=0)


def to_text(value):
    """把任意输入规范化为契约格式 ``YYYY-MM-DD HH:MM:SS``。"""
    if value is None or (isinstance(value, str) and not value.strip()):
        raise TimeContractError("时间是空值")
    return _coerce(value).strftime(CONTRACT_FORMAT)


def to_stamp(value=None):
    """把任意输入规范化为文件名时间戳 ``YYYYMMDD_HHMMSS``。"""
    if value is None:
        return now_stamp()
    return _coerce(value).strftime(STAMP_FORMAT)


def is_text(value):
    """判断字符串是否已经是契约格式（且是真实存在的日期时间）。"""
    if not isinstance(value, str) or not CONTRACT_RE.match(value):
        return False
    try:
        _dt.datetime.strptime(value, CONTRACT_FORMAT)
    except ValueError:
        return False
    return True


def is_stamp(value):
    """判断字符串是否是文件名时间戳格式。"""
    if not isinstance(value, str) or not STAMP_RE.match(value):
        return False
    try:
        _dt.datetime.strptime(value, STAMP_FORMAT)
    except ValueError:
        return False
    return True


def audit(value):
    """返回违反契约的原因列表；空列表表示合规。"""
    problems = []
    if not isinstance(value, str):
        return ["不是字符串: %r" % (value,)]
    if not CONTRACT_RE.match(value):
        problems.append("格式不是 YYYY-MM-DD HH:MM:SS")
    if "T" in value:
        problems.append("含 ISO 'T' 分隔符")
    if value.endswith("Z") or value.endswith("z"):
        problems.append("含 UTC 'Z' 后缀")
    if re.search(r"[+-]\d{2}:?\d{2}$", value):
        problems.append("含时区偏移")
    if re.search(r"(UTC|GMT)", value, re.I):
        problems.append("含 UTC/GMT 字样")
    if not problems:
        try:
            _dt.datetime.strptime(value, CONTRACT_FORMAT)
        except ValueError:
            problems.append("不是合法日期时间")
    return problems


def legacy_rfc3339(value, offset_hours=8):
    """仅供 ``--legacy-rfc3339`` 显式开启时使用，给旧 ark-kb 消费者。

    新代码不得调用。默认输出已带 +08:00 的 RFC3339。
    """
    moment = _coerce(value)
    text = moment.strftime("%Y-%m-%dT%H:%M:%S")
    if offset_hours is None:
        return text + "Z"
    offset_minutes = int(round(float(offset_hours) * 60))
    sign = "+" if offset_minutes >= 0 else "-"
    hours, minutes = divmod(abs(offset_minutes), 60)
    return "%s%s%02d:%02d" % (text, sign, hours, minutes)


def duration_text(seconds):
    """秒数转 ``1小时02分03秒`` 形式，避免出现时区相关格式。"""
    total = int(max(0, seconds))
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return "%d小时%02d分%02d秒" % (hours, minutes, secs)
    if minutes:
        return "%d分%02d秒" % (minutes, secs)
    return "%d秒" % secs


def _main(argv=None):
    parser = argparse.ArgumentParser(
        prog="ark_time", description="北京时间无时区时间契约工具"
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("now", help="输出当前北京时间")
    sub.add_parser("stamp", help="输出当前文件名时间戳")
    for name in ("normalize", "check", "legacy", "audit"):
        p = sub.add_parser(name)
        p.add_argument("value")
    args = parser.parse_args(argv)

    if args.command == "now":
        print(now_text())
        return 0
    if args.command == "stamp":
        print(now_stamp())
        return 0
    if args.command == "normalize":
        print(to_text(args.value))
        return 0
    if args.command == "check":
        return 0 if is_text(args.value) else 1
    if args.command == "legacy":
        print(legacy_rfc3339(args.value))
        return 0
    if args.command == "audit":
        problems = audit(args.value)
        if problems:
            print("; ".join(problems))
            return 1
        print("ok")
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(_main())
