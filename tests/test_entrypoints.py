# -*- coding: utf-8 -*-
"""入口脚本静态契约测试。

1. `bash -n`：bin/*.sh 与 lib/*.sh 必须语法正确。
2. 禁止内联时间格式化：除显式 `--legacy-rfc3339` 代码路径外，bin/ 与 lib/ 中
   不得出现 `%Y-%m-%dT` / `yyyy-MM-ddT` / `-Format 'yyyy-MM-ddTHH` / `date +"...T"`。
3. 每个 bin/* 文件必须有中文头部注释，写明“北京时间 / 无时区”规则。
"""

from __future__ import annotations

import glob
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ark_testlib import BIN_DIR, LIB_DIR, run  # noqa: E402

CJK_RE = re.compile(r"[\u4e00-\u9fff]")

INLINE_PATTERNS = (
    ("strftime-iso-T", re.compile(r"%Y-%m-%dT")),
    ("powershell-iso-T", re.compile(r"yyyy-MM-ddT", re.IGNORECASE)),
    ("powershell-format-iso-T", re.compile(r"-Format\s+['\"]?yyyy-MM-ddTHH", re.IGNORECASE)),
    ("date-iso-T", re.compile(r"date\s+[^'\"#\n]*%Y-%m-%dT")),
)

#: 命中行前后若出现这些标记，视为显式 legacy 兼容路径，放行
LEGACY_MARKERS = ("legacy_rfc3339", "legacy-rfc3339", "LEGACY_RFC3339")
WINDOW = 8


def _all_scripts():
    files = []
    for directory in (BIN_DIR, LIB_DIR):
        for name in sorted(os.listdir(directory)) if os.path.isdir(directory) else []:
            path = os.path.join(directory, name)
            if os.path.isfile(path):
                files.append(path)
    return files


def _shell_scripts():
    return sorted(
        glob.glob(os.path.join(BIN_DIR, "*.sh")) + glob.glob(os.path.join(LIB_DIR, "*.sh"))
    )


class EntrypointTest(unittest.TestCase):
    def test_bash_syntax_of_all_shell_scripts(self):
        scripts = _shell_scripts()
        self.assertTrue(scripts, "bin/ 与 lib/ 下没有 .sh 脚本可检查")
        for path in scripts:
            with self.subTest(script=path):
                result = run(["bash", "-n", path], timeout=60)
                self.assertEqual(
                    result.returncode,
                    0,
                    "bash -n 失败：%s\nstderr:\n%s" % (path, result.stderr),
                )

    def test_no_inline_time_formatting_outside_legacy_path(self):
        violations = []
        for path in _all_scripts():
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            lines = text.splitlines()
            for lineno, line in enumerate(lines, 1):
                if line.lstrip().startswith("#"):
                    continue  # 注释里的示例/禁令说明不算实现
                for rule, pattern in INLINE_PATTERNS:
                    if not pattern.search(line):
                        continue
                    window = "\n".join(lines[max(0, lineno - 1 - WINDOW) : lineno + WINDOW])
                    if any(marker in window for marker in LEGACY_MARKERS):
                        continue
                    violations.append(
                        "%s:%d: %s 内联时间格式：%s"
                        % (path, lineno, rule, line.strip())
                    )
        self.assertEqual(
            violations,
            [],
            "发现未走 lib/ark_time.py 的内联时间格式化（仅 --legacy-rfc3339 代码路径可豁免）：\n"
            + "\n".join(violations),
        )

    def test_every_bin_file_has_chinese_beijing_header(self):
        if not os.path.isdir(BIN_DIR):
            self.skipTest("bin/ 目录不存在")
        bin_files = [
            os.path.join(BIN_DIR, name)
            for name in sorted(os.listdir(BIN_DIR))
            if os.path.isfile(os.path.join(BIN_DIR, name))
        ]
        if not bin_files:
            self.skipTest("bin/ 为空：迁移脚本尚未落盘，无法检查中文头部")

        failures = []
        for path in bin_files:
            with open(path, encoding="utf-8", errors="replace") as handle:
                head = "\n".join(handle.read().splitlines()[:60])
            has_beijing = "北京" in head
            has_no_tz = any(
                token in head for token in ("时区", "无 T", "无T", "没有 `T`", "没有T")
            )
            if not (CJK_RE.search(head) and has_beijing and has_no_tz):
                failures.append(path)
        self.assertEqual(
            failures,
            [],
            "以下 bin/ 文件缺少中文头部“北京时间/无时区”说明：\n" + "\n".join(failures),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
