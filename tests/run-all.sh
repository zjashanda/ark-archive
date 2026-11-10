#!/usr/bin/env bash
# tests/run-all.sh —— 一键质量门禁：单元测试 + bash 冒烟 + 敏感信息扫描
#
# 用法（仓库根或任意目录）：
#   bash tests/run-all.sh
# 退出码：0 全通过；1 有失败项（会打印 FAIL 汇总）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAILED=0
section() { printf '\n===== %s =====\n' "$1"; }
fail() { echo "FAIL: $1" >&2; FAILED=1; }

section "1/3 Python 单元测试"
if python3 -m unittest discover -s tests -v; then
  echo "unittest: PASS"
else
  fail "unittest"
fi

section "2/3 bash 冒烟检查"
if bash -n tests/run-all.sh; then
  echo "语法 OK: tests/run-all.sh"
else
  fail "语法错误: tests/run-all.sh"
fi
if bash -n tools/secret-scan.sh; then
  echo "语法 OK: tools/secret-scan.sh"
else
  fail "语法错误: tools/secret-scan.sh"
fi

mapfile -t SHELL_SCRIPTS < <(find bin lib -type f -name '*.sh' 2>/dev/null | sort)
if [ ${#SHELL_SCRIPTS[@]} -eq 0 ]; then
  echo "提示: bin/ lib/ 下暂无可检查的 .sh（迁移脚本未落盘）"
else
  for script in "${SHELL_SCRIPTS[@]}"; do
    if bash -n "$script"; then
      echo "语法 OK: $script"
    else
      fail "语法错误: $script"
    fi
  done
fi

NOW_TEXT="$(python3 lib/ark_time.py now 2>/dev/null || true)"
if [[ "$NOW_TEXT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
  echo "ark_time now OK: $NOW_TEXT"
else
  fail "ark_time now 输出不合契约: ${NOW_TEXT:-<空>}"
fi
if python3 lib/ark_time.py check '2026-11-10 12:09:56' >/dev/null 2>&1; then
  echo "ark_time check 接受合规样例 OK"
else
  fail "ark_time check 拒绝合法样例"
fi
if python3 lib/ark_time.py check '2026-11-10T12:09:56Z' >/dev/null 2>&1; then
  fail "ark_time check 接受了违规样例 2026-11-10T12:09:56Z"
else
  echo "ark_time check 拒绝违规样例 OK"
fi

section "3/3 敏感信息扫描"
if bash tools/secret-scan.sh; then
  echo "secret-scan: PASS"
else
  fail "secret-scan"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS —— 全部检查通过"
  exit 0
fi
echo "FAIL —— 存在失败项，见上方输出"
exit 1
