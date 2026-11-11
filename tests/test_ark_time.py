# -*- coding: utf-8 -*-
"""时间契约（NOAH-43）单元测试：lib/ark_time.py。

约束：仅标准库；不修改 lib/；失败信息给出具体字段与期望值。
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ark_testlib import (  # noqa: E402
    CONTRACT_RE,
    LEGACY_STAMP_RE,
    LIB_DIR,
    STAMP_RE,
    assert_contract_time,
    python_exe,
    run,
)

_LIB_PATH = os.path.join(LIB_DIR, "ark_time.py")
if not os.path.isfile(_LIB_PATH):
    raise unittest.SkipTest("lib/ark_time.py 不存在：%s" % _LIB_PATH)

_spec = importlib.util.spec_from_file_location("ark_time_under_test", _LIB_PATH)
ark_time = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ark_time)


class NowTextTest(unittest.TestCase):
    def test_now_text_matches_contract_regex_and_parses(self):
        text = ark_time.now_text()
        self.assertRegex(text, CONTRACT_RE, "now_text() 不是契约格式：%r" % text)
        parsed = dt.datetime.strptime(text, "%Y-%m-%d %H:%M:%S")
        self.assertIsInstance(parsed, dt.datetime)
        for token in ("T", "Z", "+08:00", "UTC", "GMT"):
            self.assertNotIn(token, text, "now_text() 含违约片段 %r：%r" % (token, text))

    def test_now_text_is_beijing_time(self):
        """now_text() 必须比 UTC 当前时间快 8 小时（容忍 90 秒误差）。"""
        expected = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).replace(
            microsecond=0
        )
        actual = dt.datetime.strptime(ark_time.now_text(), "%Y-%m-%d %H:%M:%S").replace(
            tzinfo=dt.timezone(dt.timedelta(hours=8))
        )
        delta = abs((actual - expected).total_seconds())
        self.assertLess(delta, 90, "now_text() 与北京时间偏差 %.0f 秒" % delta)


class ToTextTest(unittest.TestCase):
    def test_utc_z_is_converted_to_beijing(self):
        self.assertEqual(
            ark_time.to_text("2026-11-09T02:54:39Z"), "2026-11-09 10:54:39"
        )

    def test_plus_08_offset_keeps_wall_clock(self):
        self.assertEqual(
            ark_time.to_text("2026-11-02T09:06:47+08:00"), "2026-11-02 09:06:47"
        )

    def test_contract_text_passes_through_unchanged(self):
        self.assertEqual(
            ark_time.to_text("2026-11-10 12:09:56"), "2026-11-10 12:09:56"
        )

    def test_epoch_seconds(self):
        moment = dt.datetime(2026, 11, 9, 2, 54, 39, tzinfo=dt.timezone.utc)
        epoch = int(moment.timestamp())
        self.assertEqual(ark_time.to_text(epoch), "2026-11-09 10:54:39")

    def test_epoch_milliseconds(self):
        moment = dt.datetime(2026, 11, 9, 2, 54, 39, tzinfo=dt.timezone.utc)
        epoch_ms = str(int(moment.timestamp()) * 1000)
        self.assertEqual(len(epoch_ms), 13, "毫秒时间戳应为 13 位数字")
        self.assertEqual(ark_time.to_text(epoch_ms), "2026-11-09 10:54:39")

    def test_naive_iso_is_treated_as_beijing(self):
        self.assertEqual(
            ark_time.to_text("2026-11-10T12:09:56"), "2026-11-10 12:09:56"
        )

    def test_none_and_blank_are_rejected(self):
        for bad in (None, "", "   "):
            with self.assertRaises(ark_time.TimeContractError, msg="应拒绝 %r" % (bad,)):
                ark_time.to_text(bad)


class IsTextTest(unittest.TestCase):
    def test_accepts_valid_contract_text(self):
        self.assertTrue(ark_time.is_text("2026-11-10 12:09:56"))

    def test_rejects_everything_not_in_contract(self):
        bad_values = [
            "2026-11-10T12:09:56",
            "2026-11-10T12:09:56Z",
            "2026-11-10T12:09:56+08:00",
            "2026-11-02 09:06:47+08:00",
            "2026-11-10 12:09:56 UTC",
            "2026-11-10 12:09",
            "2026-13-10 12:09:56",
            "2026-11-10 25:09:56",
            "2026-11-10",
            "",
            None,
            1762656879,
        ]
        for value in bad_values:
            self.assertFalse(
                ark_time.is_text(value), "is_text 不应接受 %r" % (value,)
            )


class AuditTest(unittest.TestCase):
    def test_valid_value_has_no_problems(self):
        self.assertEqual(ark_time.audit("2026-11-10 12:09:56"), [])

    def test_audit_names_t_and_offset(self):
        problems = ark_time.audit("2026-11-02T09:06:47+08:00")
        self.assertTrue(problems, "违规时间必须产生问题列表")
        joined = " | ".join(problems)
        self.assertTrue(
            any("格式" in p for p in problems), "未指出格式违规：%s" % joined
        )
        self.assertTrue(
            any("'T'" in p or p.startswith("含 ISO") for p in problems),
            "未指出 T 分隔符：%s" % joined,
        )
        self.assertTrue(
            any("偏移" in p for p in problems), "未指出时区偏移：%s" % joined
        )

    def test_audit_names_z_suffix(self):
        problems = ark_time.audit("2026-11-10 12:09:56Z")
        self.assertTrue(
            any("Z" in p for p in problems), "未指出 Z 后缀：%r" % problems
        )

    def test_audit_names_utc_word(self):
        problems = ark_time.audit("2026-11-10 12:09:56 UTC")
        self.assertTrue(
            any("UTC" in p or "GMT" in p for p in problems),
            "未指出 UTC/GMT 字样：%r" % problems,
        )


class StampTest(unittest.TestCase):
    def test_to_stamp_none_matches_filename_pattern(self):
        stamp = ark_time.to_stamp(None)
        self.assertRegex(stamp, STAMP_RE, "to_stamp(None) 不是 YYYYMMDD-HHMMSS：%r" % stamp)
        dt.datetime.strptime(stamp, "%Y%m%d-%H%M%S")

    def test_to_stamp_from_text(self):
        self.assertEqual(ark_time.to_stamp("2026-11-10 12:09:56"), "20261110-120956")

    def test_legacy_underscore_stamp_is_detected_as_legacy_only(self):
        self.assertTrue(ark_time.is_legacy_stamp("20261110_120956"))
        self.assertFalse(ark_time.is_stamp("20261110_120956"))

    def test_hyphen_stamp_is_current_and_not_legacy(self):
        self.assertTrue(ark_time.is_stamp("20261110-120956"))
        self.assertFalse(ark_time.is_legacy_stamp("20261110-120956"))

    def test_stamp_regexes_split_current_and_legacy(self):
        self.assertRegex("20261110-120956", STAMP_RE)
        self.assertRegex("20261110_120956", LEGACY_STAMP_RE)
        self.assertNotRegex("20261110_120956", STAMP_RE)
        self.assertNotRegex("20261110-120956", LEGACY_STAMP_RE)

    def test_both_stamp_helpers_reject_invalid_calendar_dates(self):
        for bad in ("20261310-120956", "20261110-250956"):
            self.assertFalse(ark_time.is_stamp(bad), "is_stamp 不应接受 %r" % (bad,))
        for bad in ("20261310_120956", "20261110_250956"):
            self.assertFalse(
                ark_time.is_legacy_stamp(bad), "is_legacy_stamp 不应接受 %r" % (bad,)
            )


class LegacyStampCliTest(unittest.TestCase):
    def test_legacy_stamp_cli_prints_hyphen_format(self):
        result = run(
            [
                python_exe(),
                os.path.join(LIB_DIR, "ark_time.py"),
                "legacy-stamp",
                "20261110_120956",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "20261110-120956")

    def test_legacy_stamp_cli_rejects_current_format(self):
        result = run(
            [
                python_exe(),
                os.path.join(LIB_DIR, "ark_time.py"),
                "legacy-stamp",
                "20261110-120956",
            ]
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("不是历史文件名时间戳", result.stderr)


class LegacyAndDurationTest(unittest.TestCase):
    def test_legacy_rfc3339_emits_plus_08(self):
        text = ark_time.legacy_rfc3339("2026-11-10 12:09:56")
        self.assertEqual(text, "2026-11-10T12:09:56+08:00")
        self.assertIn("T", text)
        self.assertTrue(text.endswith("+08:00"))

    def test_legacy_rfc3339_utc_shift(self):
        self.assertEqual(
            ark_time.legacy_rfc3339("2026-11-09T02:54:39Z"),
            "2026-11-09T10:54:39+08:00",
        )

    def test_duration_text(self):
        cases = {
            3723: "1小时02分03秒",
            63: "1分03秒",
            9: "9秒",
            0: "0秒",
            -5: "0秒",
        }
        for seconds, expected in cases.items():
            self.assertEqual(
                ark_time.duration_text(seconds),
                expected,
                "duration_text(%r) 期望 %r" % (seconds, expected),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
