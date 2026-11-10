# -*- coding: utf-8 -*-
"""`bin/ark-prune.sh` 保留策略测试。

覆盖：默认 dry-run 不删除任何东西；--apply --yes 只删白名单内过期文件；
summary_final.json 与白名单外的旧文件必须保留；危险根目录/不存在的根被拒绝。
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ark_testlib import BIN_DIR, run, skip_without  # noqa: E402

SCRIPT = os.path.join(BIN_DIR, "ark-prune.sh")
REFUSED_ROOTS = ("/", "/srv", "/srv/storage", "/srv/storage/ark")


class PruneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ark-prune-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        skip_without(self, SCRIPT)

        self.root = os.path.join(self.tmp, "results")
        base = os.path.join(self.root, "win009", "tcl-r5")
        os.makedirs(os.path.join(base, "serial_logs"))
        self.old_serial = self._make(os.path.join(base, "serial_logs", "old.log"), 40)
        self.fresh_serial = self._make(os.path.join(base, "serial_logs", "fresh.log"), 1)
        self.old_tool = self._make(os.path.join(base, "tool.log"), 100)
        self.summary = self._make(os.path.join(base, "summary_final.json"), 400)
        self.keep = self._make(os.path.join(base, "keepme.log"), 400)

    def _make(self, path: str, age_days: int) -> str:
        with open(path, "wb") as handle:
            handle.write(b"x" * 32)
        stamp = time.time() - age_days * 86400
        os.utime(path, (stamp, stamp))
        return path

    def _prune(self, extra):
        return run(["bash", SCRIPT, "--root", self.root] + list(extra), timeout=120)

    def test_dry_run_deletes_nothing(self):
        result = self._prune([])
        self.assertEqual(
            result.returncode,
            0,
            "dry-run 应退出 0，实际 %d\nstdout:\n%s\nstderr:\n%s"
            % (result.returncode, result.stdout, result.stderr),
        )
        for path in (
            self.old_serial,
            self.fresh_serial,
            self.old_tool,
            self.summary,
            self.keep,
        ):
            self.assertTrue(os.path.exists(path), "dry-run 不应删除 %s" % path)
        self.assertIn("old.log", result.stdout, "dry-run 应列出过期 serial 日志")
        self.assertIn("tool.log", result.stdout, "dry-run 应列出过期 tool.log")
        self.assertNotIn("keepme.log", result.stdout, "白名单外的文件不应成为候选")
        self.assertNotIn("fresh.log", result.stdout, "未过期文件不应成为候选")

    def test_apply_removes_only_whitelisted_expired_files(self):
        result = self._prune(["--apply", "--yes"])
        self.assertEqual(
            result.returncode,
            0,
            "--apply --yes 应退出 0，实际 %d\nstdout:\n%s\nstderr:\n%s"
            % (result.returncode, result.stdout, result.stderr),
        )
        self.assertFalse(os.path.exists(self.old_serial), "过期的 serial_logs/*.log 应被删除")
        self.assertFalse(os.path.exists(self.old_tool), "过期的 tool.log 应被删除")
        self.assertTrue(os.path.exists(self.fresh_serial), "未过期的 serial 日志必须保留")
        self.assertTrue(os.path.exists(self.summary), "summary_final.json 必须永久保留")
        self.assertTrue(os.path.exists(self.keep), "白名单外的旧文件必须保留")

    def test_refused_roots_are_rejected(self):
        for root in REFUSED_ROOTS:
            with self.subTest(root=root):
                result = run(["bash", SCRIPT, "--root", root], timeout=90)
                self.assertIn(
                    result.returncode,
                    (2, 5),
                    "危险根 %r 必须退出 2/5，实际 %d\nstdout:\n%s\nstderr:\n%s"
                    % (root, result.returncode, result.stdout, result.stderr),
                )

    def test_missing_root_is_rejected(self):
        missing = os.path.join(self.tmp, "does-not-exist")
        result = run(["bash", SCRIPT, "--root", missing], timeout=60)
        self.assertIn(
            result.returncode,
            (2, 5),
            "不存在的根必须退出 2/5，实际 %d\nstderr:\n%s"
            % (result.returncode, result.stderr),
        )

    def test_usage_unknown_flag_exits_2(self):
        result = run(["bash", SCRIPT, "--root", self.root, "--nonsense"], timeout=60)
        self.assertEqual(
            result.returncode,
            2,
            "未知参数必须退出 2，实际 %d\nstderr:\n%s"
            % (result.returncode, result.stderr),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
