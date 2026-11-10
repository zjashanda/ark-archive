# -*- coding: utf-8 -*-
"""`bin/ark-archive.sh --dry-run` 清单契约测试。

覆盖：必填字段、files[] 的 sha256/字节数、软链接跳过、时间契约格式、
以及 dry-run 全程不触碰 ssh/scp/rsync（用假命令哨兵证明）。
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ark_testlib import (  # noqa: E402
    BIN_DIR,
    assert_contract_time,
    extract_manifest,
    run,
    sha256_file,
    skip_without,
)

SCRIPT = os.path.join(BIN_DIR, "ark-archive.sh")
RUN_ID = "20261102_090644_wake_recognition"
REQUIRED_FIELDS = (
    "run_id",
    "project",
    "device",
    "node",
    "result",
    "started_at",
    "ended_at",
    "files",
    "archived_at",
    "source_dir",
)


class ManifestDryRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ark-manifest-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        skip_without(self, SCRIPT)

        self.source = os.path.join(self.tmp, "run_src")
        os.makedirs(os.path.join(self.source, "logs"))
        self._write("a.txt", b"alpha\n")
        self._write("logs/b.log", b"bravo\n")
        self._write(
            "summary_final.json",
            json.dumps(
                {
                    "started_at": "2026-11-02T09:06:47+08:00",
                    "ended_at": "2026-11-02T10:00:00+08:00",
                    "normal_window": {"recognition_rate": 0.95},
                }
            ).encode("utf-8"),
        )
        # 软链接必须被跳过（不是普通文件）
        os.symlink("a.txt", os.path.join(self.source, "link.txt"))

    def _write(self, rel, data: bytes) -> None:
        path = os.path.join(self.source, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)

    def _dry_run(self, env=None):
        cmd = [
            "bash",
            SCRIPT,
            "--source",
            self.source,
            "--project",
            "demo",
            "--run-id",
            RUN_ID,
            "--node",
            "testnode",
            "--device",
            "T14",
            "--dry-run",
        ]
        return run(cmd, env=env, timeout=120)

    def _manifest(self):
        result = self._dry_run()
        self.assertEqual(
            result.returncode,
            0,
            "dry-run 应退出 0，实际 %d\nstdout:\n%s\nstderr:\n%s"
            % (result.returncode, result.stdout, result.stderr),
        )
        return extract_manifest(result.stdout)

    def test_required_fields_present(self):
        manifest = self._manifest()
        for field in REQUIRED_FIELDS:
            self.assertIn(field, manifest, "清单缺少 v1 必填字段 %r" % field)
        self.assertEqual(manifest["run_id"], RUN_ID)
        self.assertEqual(manifest["project"], "demo")
        self.assertEqual(manifest["node"], "testnode")
        self.assertEqual(manifest["device"], "T14")

    def test_file_hashes_match_fresh_sha256(self):
        manifest = self._manifest()
        files = manifest["files"]
        self.assertIsInstance(files, list, "files 必须是数组")
        self.assertTrue(files, "files 不能为空")
        by_path = {item["path"]: item for item in files}
        expected_paths = {"a.txt", "logs/b.log", "summary_final.json"}
        self.assertEqual(
            set(by_path), expected_paths, "清单文件集合不符（软链接不应出现）"
        )
        for rel, item in by_path.items():
            self.assertRegex(
                item["sha256"], r"^[0-9a-f]{64}$", "%s 的 sha256 不是 64 位小写十六进制" % rel
            )
            local = os.path.join(self.source, rel)
            self.assertEqual(
                item["sha256"], sha256_file(local), "%s 的 sha256 与本地重算不一致" % rel
            )
            self.assertEqual(
                item["bytes"], os.path.getsize(local), "%s 的 bytes 与实际大小不一致" % rel
            )
            self.assertNotIn("\\", rel, "path 必须使用正斜杠：%r" % rel)

    def test_symlink_is_skipped(self):
        manifest = self._manifest()
        paths = {item["path"] for item in manifest["files"]}
        self.assertNotIn("link.txt", paths, "软链接不应进入清单")

    def test_times_match_contract(self):
        manifest = self._manifest()
        for key in ("started_at", "ended_at", "archived_at"):
            assert_contract_time(self, manifest.get(key), key)
            for token in ("T", "Z", "+08:00"):
                self.assertNotIn(
                    token, manifest[key], "%s 含违约片段 %r：%r" % (key, token, manifest[key])
                )
        # summary 里的 ISO(+08:00) 必须被规范化，而不是原样透传
        self.assertEqual(manifest["started_at"], "2026-11-02 09:06:47")
        self.assertEqual(manifest["ended_at"], "2026-11-02 10:00:00")

    def test_dry_run_opens_no_ssh(self):
        shim = os.path.join(self.tmp, "shim")
        os.makedirs(shim)
        sentinel = os.path.join(self.tmp, "ssh-was-called")
        for name in ("ssh", "scp", "rsync", "sshpass"):
            path = os.path.join(shim, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "#!/usr/bin/env bash\n"
                    'printf "%s %s\\n" "$0" "$*" >> "$ARK_SSH_SENTINEL"\n'
                    "exit 1\n"
                )
            os.chmod(path, 0o755)
        env = {
            "ARK_SSH_SENTINEL": sentinel,
            "PATH": shim + os.pathsep + os.environ.get("PATH", ""),
        }
        result = self._dry_run(env=env)
        self.assertEqual(
            result.returncode,
            0,
            "假 ssh/scp 环境下列表 dry-run 应仍退出 0，实际 %d\n%s"
            % (result.returncode, result.stderr),
        )
        self.assertFalse(
            os.path.exists(sentinel),
            "dry-run 不应调用 ssh/scp/rsync/sshpass，但哨兵文件被写入：\n"
            + (open(sentinel, encoding="utf-8").read() if os.path.exists(sentinel) else ""),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
