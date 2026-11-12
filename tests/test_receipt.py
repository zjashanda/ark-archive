# -*- coding: utf-8 -*-
"""`bin/ark_receipt.py` 回执契约测试。

覆盖：run.receipt.v1 payload 形状、result 映射、契约时间、证据 sha256、
dry-run 不落盘、损坏文件退出 3、非法 manifest 退出 2、缺失 lib 退出 5。
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ark_testlib import (  # noqa: E402
    BIN_DIR,
    FIXTURES_DIR,
    assert_contract_time,
    extract_receipt,
    python_exe,
    run,
    sha256_file,
    skip_without,
)

SCRIPT = os.path.join(BIN_DIR, "ark_receipt.py")
SCHEMA_PATH = os.path.join(os.path.dirname(BIN_DIR), "schemas", "receipt.v1.json")
RID = "20261102-090644_wake_recognition"
NODE = "win009"
PROJECT = "tcl-r5"
REQUIRED_KEYS = (
    "schema",
    "run_id",
    "task",
    "skill",
    "skill_version",
    "scope",
    "result",
    "totals",
    "failures",
    "bugs_found",
    "evidence_dir",
    "evidence_sha256",
    "evidence_files",
    "lessons",
    "confidence",
    "started_at",
    "ended_at",
    "notes",
    "tags",
    "archive",
)


_TYPE_CHECKS = {
    "object": lambda value: isinstance(value, dict),
    "array": lambda value: isinstance(value, list),
    "string": lambda value: isinstance(value, str),
    "integer": lambda value: isinstance(value, int) and not isinstance(value, bool),
    "number": lambda value: isinstance(value, (int, float)) and not isinstance(value, bool),
    "boolean": lambda value: isinstance(value, bool),
    "null": lambda value: value is None,
}


def schema_errors(schema, value, path="receipt"):
    """校验 receipt.v1.json 实际用到的 draft-07 关键字，只用标准库。

    仓库测试不引入第三方依赖；这里覆盖 type / required / properties /
    additionalProperties / items / enum / const / pattern / minLength /
    minItems / uniqueItems / minimum / maximum，足以验证 `checkpoints`
    及其与既有字段的兼容性。
    """
    errors = []
    expected = schema.get("type")
    if expected is not None:
        options = expected if isinstance(expected, list) else [expected]
        if not any(_TYPE_CHECKS[name](value) for name in options):
            return ["%s: 类型应为 %s，实际 %s" % (path, options, type(value).__name__)]
    if "const" in schema and value != schema["const"]:
        errors.append("%s: 必须等于 %r" % (path, schema["const"]))
    if "enum" in schema and value not in schema["enum"]:
        errors.append("%s: %r 不在枚举 %r 内" % (path, value, schema["enum"]))
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append("%s: 长度小于 %d" % (path, schema["minLength"]))
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append("%s: %r 不匹配 %r" % (path, value, schema["pattern"]))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append("%s: 小于下界 %r" % (path, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            errors.append("%s: 大于上界 %r" % (path, schema["maximum"]))
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append("%s: 缺少必填键 %r" % (path, key))
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            if key in props:
                errors.extend(schema_errors(props[key], item, "%s.%s" % (path, key)))
            elif extra is False:
                errors.append("%s: 不允许的键 %r" % (path, key))
            elif isinstance(extra, dict):
                errors.extend(schema_errors(extra, item, "%s.%s" % (path, key)))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append("%s: 元素少于 %d" % (path, schema["minItems"]))
        if schema.get("uniqueItems"):
            seen = {json.dumps(item, sort_keys=True) for item in value}
            if len(seen) != len(value):
                errors.append("%s: 存在重复元素" % path)
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(value):
                errors.extend(schema_errors(item_schema, item, "%s[%d]" % (path, index)))
    return errors


class ReceiptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ark-receipt-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        skip_without(self, SCRIPT)

        self.archive = os.path.join(self.tmp, "archive")
        self.store = os.path.join(self.tmp, "store")
        os.makedirs(os.path.join(self.archive, "wav"))
        self.wav_bytes = b"RIFF-fake-wav-payload-0123456789"
        self.log_bytes = b"errors: none\n"
        self._write_archive_file("wav/ok.wav", self.wav_bytes)
        self._write_archive_file("errors.log", self.log_bytes)

        self.manifest = {
            "run_id": RID,
            "project": PROJECT,
            "device": "T14",
            "node": NODE,
            "result": "PASS",
            "started_at": "2026-11-02 09:06:47",
            "ended_at": "2026-11-02 10:00:00",
            "archived_at": "2026-11-02 10:00:06",
            "source_dir": os.path.join(self.tmp, "src"),
            "files": [
                {
                    "path": "wav/ok.wav",
                    "bytes": len(self.wav_bytes),
                    "sha256": sha256_file(os.path.join(self.archive, "wav", "ok.wav")),
                },
                {
                    "path": "errors.log",
                    "bytes": len(self.log_bytes),
                    "sha256": sha256_file(os.path.join(self.archive, "errors.log")),
                },
            ],
        }
        self.manifest_path = os.path.join(self.archive, "manifest.json")
        with open(self.manifest_path, "w", encoding="utf-8") as handle:
            json.dump(self.manifest, handle, ensure_ascii=False, indent=2)

        self.summary_path = os.path.join(self.archive, "summary_final.json")
        shutil.copyfile(
            os.path.join(FIXTURES_DIR, "sample_summary_final.json"), self.summary_path
        )
        self.out_path = os.path.join(self.tmp, "run.receipt.json")

    def _write_archive_file(self, rel, data: bytes) -> None:
        path = os.path.join(self.archive, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)

    def _receipt(self, extra, manifest_path=None):
        cmd = [
            python_exe(),
            SCRIPT,
            "--manifest",
            manifest_path or self.manifest_path,
            "--summary",
            self.summary_path,
            "--node",
            NODE,
            "--project",
            PROJECT,
            "--run-id",
            RID,
            "--storage-root",
            self.store,
            "--out",
            self.out_path,
        ]
        return run(cmd + list(extra), timeout=120)

    def _assert_ok(self, result, label):
        self.assertEqual(
            result.returncode,
            0,
            "%s 应退出 0，实际 %d\nstdout:\n%s\nstderr:\n%s"
            % (label, result.returncode, result.stdout, result.stderr),
        )

    # ------------------------------------------------------------------ 用例
    def test_dry_run_payload_shape(self):
        result = self._receipt(["--dry-run"])
        self._assert_ok(result, "--dry-run")
        receipt = extract_receipt(result.stdout)
        for key in REQUIRED_KEYS:
            self.assertIn(key, receipt, "回执缺少 run.receipt.v1 字段 %r" % key)
        self.assertEqual(receipt["schema"], "run.receipt.v1")
        self.assertEqual(receipt["run_id"], RID)
        self.assertEqual(receipt["result"], "pass", "PASS 必须映射为 pass")
        self.assertEqual(receipt["scope"]["project"], PROJECT)
        self.assertEqual(receipt["scope"]["device"], "T14")
        self.assertFalse(
            os.path.exists(self.out_path), "--dry-run 不应写出回执文件 %s" % self.out_path
        )

    def test_receipt_accepts_optional_kb_context_and_delivery(self):
        """kb_context / delivery 是可选顶层字段：缺失仍合法，写入后不破坏 required。"""
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        # 现有用例的校验口径：required 全在、schema 值正确，即为合法回执。
        for key in REQUIRED_KEYS:
            self.assertIn(key, receipt, "回执缺少 run.receipt.v1 字段 %r" % key)
        self.assertNotIn("kb_context", receipt, "kb_context 必须可选，生成器默认不写")
        self.assertNotIn("delivery", receipt, "delivery 必须可选，生成器默认不写")

        with open(SCHEMA_PATH, encoding="utf-8") as handle:
            schema = json.load(handle)
        self.assertEqual(
            set(schema["required"]), set(REQUIRED_KEYS), "本次变更不得改动 required"
        )
        self.assertNotIn(
            "additionalProperties", schema, "根对象保持开放，未使用的新键不应被拒绝"
        )
        for name, contract in (
            ("kb_context", "ark.kb-context.v1"),
            ("delivery", "ark.delivery.v1"),
        ):
            prop = schema["properties"][name]
            self.assertEqual(prop["type"], "object", "%s 必须是 object" % name)
            self.assertIn(contract, prop["description"], "%s 应指向 %s" % (name, contract))
            self.assertNotIn(name, schema["required"], "%s 不得进入 required" % name)

        extended = dict(receipt)
        extended["kb_context"] = {
            "schema": "ark.kb-context.v1",
            "contract_version": "1.0.0",
            "queried_at": "2026-11-12 16:40:00",
            "dims": {
                "capability": [],
                "project": PROJECT,
                "device": "T14",
                "firmware": None,
                "profile": "",
                "skill": "ark-archive",
            },
            "registry_commit": "unknown",
            "hits": [],
            "no_hit": True,
            "refresh_points": [{"at": "stage:1", "reason": "首次查询"}],
            "refresh_log": [],
        }
        extended["delivery"] = {
            "schema": "ark.delivery.v1",
            "run_id": RID,
            "idempotency_key": "0" * 64,
            "archive_status": "ok",
            "archive_manifest_sha256": receipt["archive"]["manifest_sha256"],
            "kb_ingest_status": "pending",
            "kb_entry_ids": [],
            "kb_query_back_status": "pending",
            "kb_query_back_at": "",
            "kb_query_back_hits": [],
            "no_kb_reason": "",
            "retry": {"attempts": 0, "last_error": ""},
            "updated_at": "2026-11-12 16:41:00",
        }
        for key in REQUIRED_KEYS:
            self.assertIn(key, extended, "附加可选字段后仍须保留 %r" % key)
        self.assertEqual(extended["delivery"]["schema"], "ark.delivery.v1")
        self.assertEqual(extended["delivery"]["archive_status"], "ok")
        self.assertEqual(
            extended["delivery"]["archive_manifest_sha256"],
            receipt["archive"]["manifest_sha256"],
            "archive_manifest_sha256 必须与回执 archive 段一致",
        )
        self.assertEqual(extended["kb_context"]["schema"], "ark.kb-context.v1")
        self.assertIsInstance(json.loads(json.dumps(extended)), dict)

    def _schema(self):
        with open(SCHEMA_PATH, encoding="utf-8") as handle:
            return json.load(handle)

    def _validate(self, receipt):
        return schema_errors(self._schema(), receipt)

    def test_receipt_without_checkpoints_still_validates(self):
        """`checkpoints` 是可选字段：老回执不带它也必须通过 schema 校验。"""
        schema = self._schema()
        self.assertIn("checkpoints", schema["properties"], "schema 应新增 checkpoints 属性")
        self.assertNotIn(
            "checkpoints", schema["required"], "checkpoints 必须可选，不得进入 required"
        )
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        self.assertNotIn("checkpoints", receipt, "生成器默认不写 checkpoints")
        self.assertEqual(self._validate(receipt), [], "不带 checkpoints 的回执应当合法")

    def test_receipt_with_valid_checkpoints_validates(self):
        """带合法 checkpoints 数组的回执通过 schema 校验，且不破坏既有字段。"""
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        receipt["checkpoints"] = [
            {
                "checkpoint_id": "a" * 64,
                "trigger": "EXECUTION_CHECK",
                "quality": "formal",
                "at": "2026-11-12 17:30:00",
            },
            {
                "checkpoint_id": "b" * 64,
                "trigger": "WATCHDOG_HEARTBEAT_LOST",
                "quality": "candidate",
                "at": "2026-11-12 17:35:00",
            },
        ]
        for key in REQUIRED_KEYS:
            self.assertIn(key, receipt, "附加 checkpoints 后仍须保留 %r" % key)
        trigger_enum = self._schema()["properties"]["checkpoints"]["items"]["properties"][
            "trigger"
        ]["enum"]
        self.assertEqual(len(trigger_enum), 12, "trigger 必须是 12 值封闭枚举")
        self.assertNotIn("FINAL_RECEIPT", trigger_enum, "FINAL_RECEIPT 只聚合，不是检查点")
        self.assertEqual(self._validate(receipt), [], "合法 checkpoints 应当通过校验")

    def test_receipt_with_invalid_trigger_is_rejected(self):
        """非法 trigger 必须被 schema 拒绝，而不是被静默接受。"""
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        receipt["checkpoints"] = [
            {
                "checkpoint_id": "c" * 64,
                "trigger": "NOT_A_TRIGGER",
                "quality": "formal",
                "at": "2026-11-12 17:40:00",
            }
        ]
        errors = self._validate(receipt)
        self.assertTrue(errors, "非法 trigger 必须产生校验错误")
        self.assertTrue(
            any("trigger" in message for message in errors),
            "校验错误应定位到 trigger：%r" % errors,
        )

    def test_dry_run_totals(self):
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        totals = receipt["totals"]
        self.assertEqual(totals["recognition_rate"], 0.95, "识别率必须来自 summary_final.json")
        self.assertEqual(totals["rounds"], 100)
        self.assertEqual(totals["target_rounds"], 100)
        self.assertEqual(totals["archived_files"], 2)
        self.assertEqual(totals["archived_bytes"], len(self.wav_bytes) + len(self.log_bytes))

    def test_times_are_contract_format(self):
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        for key in ("started_at", "ended_at"):
            assert_contract_time(self, receipt[key], key)
            self.assertNotIn("T", receipt[key], "%s 含 ISO T：%r" % (key, receipt[key]))
            self.assertNotIn("Z", receipt[key], "%s 含 Z：%r" % (key, receipt[key]))
            self.assertNotIn("+08:00", receipt[key], "%s 含偏移：%r" % (key, receipt[key]))
        self.assertEqual(receipt["started_at"], "2026-11-02 09:06:47")
        self.assertEqual(receipt["ended_at"], "2026-11-02 10:00:00")

    def test_evidence_hashes_and_dir(self):
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        expected = sorted([self.manifest["files"][0]["sha256"], self.manifest["files"][1]["sha256"]])
        self.assertEqual(sorted(receipt["evidence_sha256"]), expected)
        file_hashes = {item["path"]: item["sha256"] for item in receipt["evidence_files"]}
        self.assertEqual(file_hashes, {item["path"]: item["sha256"] for item in self.manifest["files"]})
        expected_dir = os.path.join(self.store, "results", NODE, PROJECT, RID)
        self.assertEqual(
            os.path.normpath(receipt["evidence_dir"]),
            os.path.normpath(expected_dir),
            "evidence_dir 必须指向存储路径",
        )

    def test_full_run_prints_contract_keys_and_verifies_sha(self):
        result = self._receipt([])
        self._assert_ok(result, "完整生成")
        self.assertTrue(os.path.isfile(self.out_path), "完整生成后回执文件应存在")
        for key in ("VERIFY", "RECEIPT", "RECEIPT_SHA256", "EVIDENCE_DIR", "RESULT"):
            self.assertRegex(
                result.stdout,
                r"(?m)^%s\s*[:=]" % key,
                "stdout 缺少输出键 %s=：\n%s" % (key, result.stdout),
            )
        match = re.search(r"(?m)^RECEIPT_SHA256\s*[:=]\s*([0-9a-f]{64})", result.stdout)
        self.assertIsNotNone(match, "RECEIPT_SHA256 后应跟 64 位十六进制：\n%s" % result.stdout)
        self.assertEqual(
            match.group(1), sha256_file(self.out_path), "RECEIPT_SHA256 与实际文件哈希不一致"
        )
        with open(self.out_path, encoding="utf-8") as handle:
            payload = json.load(handle)
        self.assertEqual(payload["result"], "pass")
        assert_contract_time(self, payload["started_at"], "receipt.started_at")

    def test_corrupted_evidence_exits_3(self):
        with open(os.path.join(self.archive, "wav", "ok.wav"), "wb") as handle:
            handle.write(b"tampered")
        result = self._receipt([])
        self.assertEqual(
            result.returncode,
            3,
            "本地哈希不一致必须退出 3，实际 %d\nstdout:\n%s\nstderr:\n%s"
            % (result.returncode, result.stdout, result.stderr),
        )

    def test_invalid_manifest_exits_2(self):
        bad = os.path.join(self.tmp, "manifest.bad.json")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write("{not valid json")
        result = self._receipt(["--dry-run"], manifest_path=bad)
        self.assertEqual(
            result.returncode,
            2,
            "非法 manifest 必须退出 2，实际 %d\nstderr:\n%s"
            % (result.returncode, result.stderr),
        )

    def _variant(self, result, summary):
        manifest = dict(self.manifest)
        manifest["result"] = result
        path = os.path.join(self.tmp, "manifest.%s.json" % result.lower())
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2)
        summary_path = os.path.join(self.tmp, "summary.%s.json" % result.lower())
        with open(summary_path, "w", encoding="utf-8") as handle:
            json.dump(summary, handle, ensure_ascii=False, indent=2)
        return path, summary_path

    def test_recognized_result_without_failures_normalizes_to_pass(self):
        summary = {
            "completed_rounds": 100,
            "target_rounds": 100,
            "normal_window": {"recognized": 95, "failed": 0, "recognition_rate": 0.95},
            "status_counts": {"RECOGNIZED": 95, "UNKNOWN": 5},
        }
        manifest_path, summary_path = self._variant("RECOGNIZED", summary)
        result = self._receipt(
            ["--dry-run", "--summary", summary_path], manifest_path=manifest_path
        )
        self._assert_ok(result, "RECOGNIZED + failed=0")
        receipt = extract_receipt(result.stdout)
        self.assertEqual(receipt["result"], "pass")
        source = receipt["result_source"]
        self.assertTrue(source["normalized"])
        self.assertEqual(source["derived_from"], "status_counts")
        self.assertEqual(source["raw_result"], "RECOGNIZED")
        self.assertEqual(source["failed"], 0)
        self.assertEqual(source["status_counts"], {"RECOGNIZED": 95, "UNKNOWN": 5})
        self.assertEqual(receipt["totals"]["status_counts"], {"RECOGNIZED": 95, "UNKNOWN": 5})
        self.assertIn("NORMALIZED", result.stderr)

    def test_recognized_result_with_failures_normalizes_to_fail(self):
        summary = {
            "completed_rounds": 10,
            "target_rounds": 10,
            "normal_window": {"recognized": 9, "failed": 1, "recognition_rate": 0.9},
            "status_counts": {"RECOGNIZED": 9, "NOT_RECOGNIZED": 1},
        }
        manifest_path, summary_path = self._variant("RECOGNIZED", summary)
        result = self._receipt(
            ["--dry-run", "--summary", summary_path], manifest_path=manifest_path
        )
        self._assert_ok(result, "RECOGNIZED + failed>0")
        receipt = extract_receipt(result.stdout)
        self.assertEqual(receipt["result"], "fail")
        self.assertEqual(receipt["result_source"]["failed"], 1)
        self.assertEqual(receipt["failures"][0]["name"], "唤醒/命令词识别失败")
        self.assertEqual(receipt["tags"], sorted({"archive", NODE, PROJECT, "fail"}))

    def test_counted_failures_normalize_without_normal_window(self):
        summary = {"completed_rounds": 4, "status_counts": {"RECOGNIZED": 3, "NOT_RECOGNIZED": 1}}
        manifest_path, summary_path = self._variant("UNRECOGNIZED", summary)
        result = self._receipt(
            ["--dry-run", "--summary", summary_path], manifest_path=manifest_path
        )
        self._assert_ok(result, "只有 status_counts")
        receipt = extract_receipt(result.stdout)
        self.assertEqual(receipt["result"], "fail")
        self.assertEqual(receipt["result_source"]["failed"], 1)

    def test_unknown_result_without_counts_exits_2(self):
        summary = {"completed_rounds": 10, "target_rounds": 10}
        manifest_path, summary_path = self._variant("RECOGNIZED", summary)
        result = self._receipt(
            ["--dry-run", "--summary", summary_path], manifest_path=manifest_path
        )
        self.assertEqual(
            result.returncode,
            2,
            "无计数证据时不得猜测结果，必须退出 2，实际 %d\nstderr:\n%s"
            % (result.returncode, result.stderr),
        )
        self.assertIn("status_counts", result.stderr)

    def test_known_result_is_not_marked_normalized(self):
        receipt = extract_receipt(self._receipt(["--dry-run"]).stdout)
        source = receipt["result_source"]
        self.assertFalse(source["normalized"])
        self.assertEqual(source["derived_from"], "result_map")
        self.assertEqual(source["raw_result"], "PASS")
        self.assertFalse(os.path.exists(self.out_path))

    def test_missing_lib_exits_5(self):
        """把脚本复制到没有 lib/ 的目录，必须退出 5 而不是崩溃/成功。"""
        isolated = os.path.join(self.tmp, "isolated")
        os.makedirs(os.path.join(isolated, "bin"))
        copied = os.path.join(isolated, "bin", "ark_receipt.py")
        shutil.copyfile(SCRIPT, copied)
        result = run(
            [
                python_exe(),
                copied,
                "--manifest",
                self.manifest_path,
                "--summary",
                self.summary_path,
                "--dry-run",
            ],
            cwd=isolated,
            env={"PYTHONPATH": ""},
            timeout=120,
        )
        self.assertEqual(
            result.returncode,
            5,
            "缺失 lib/ 时必须退出 5，实际 %d\nstdout:\n%s\nstderr:\n%s"
            % (result.returncode, result.stdout, result.stderr),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
