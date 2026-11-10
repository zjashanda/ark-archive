#!/usr/bin/env bash
# tools/secret-scan.sh —— 仓库敏感信息扫描（CI 安全门禁）
#
# 规则：命中即输出 file:line: rule 并以 1 退出，全干净退出 0。
#   - 递归扫描仓库树；跳过 .git/、tests/fixtures/expected/、__pycache__/
#   - 命中行可用行内标记 `ark-scan:allow` 单独放行
#   - 输出只显示掩码后的片段，绝不完整打印疑似密钥
#
# 用法：
#   bash tools/secret-scan.sh            # 扫描仓库根
#   bash tools/secret-scan.sh <dir>      # 扫描指定目录（自测用）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$ROOT}"
cd "$TARGET" 2>/dev/null || { echo "secret-scan: 无法进入目录 $TARGET" >&2; exit 2; }

# 规则表：名称;;grep -E 正则
# 注意：规则里的敏感字面量要用字符类拆开书写，否则扫描器会命中自己。
RULES=(
  "github-token;;gh[pousr]_[A-Za-z0-9]{20,}"
  "github-pat;;github_pat_[A-Za-z0-9_]{20,}"
  "openai-key;;sk-[A-Za-z0-9]{20,}"
  "aws-access-key;;AKIA[0-9A-Z]{16}"
  "private-key;;-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "x-access-token;;x[-]access[-]token:"
  "bearer-token;;Authorization[:][[:space:]]+Bearer"
  "password-assign;;password[[:space:]]*[:=][[:space:]]*[^[:space:]]+"
  "passwd-assign;;passwd[[:space:]]*[:=][[:space:]]*[^[:space:]]+"
  "lan-password;;10\\.11\\.63\\.[0-9]+[[:space:]]+.*(password|pass)"
)

mask() {
  local value="$1"
  local length=${#value}
  if (( length <= 6 )); then
    printf '%s***' "${value:0:2}"
  else
    printf '%s***%s' "${value:0:4}" "${value: -2}"
  fi
}

mapfile -t FILES < <(
  find . -type f \
    -not -path './.git/*' \
    -not -path './tests/fixtures/expected/*' \
    -not -path '*/__pycache__/*' \
    -print 2>/dev/null
)

HIT=0
for file in "${FILES[@]}"; do
  [ -f "$file" ] || continue
  for rule in "${RULES[@]}"; do
    name="${rule%%;;*}"
    regex="${rule#*;;}"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      lineno="${line%%:*}"
      content="${line#*:}"
      case "$content" in
        *"ark-scan:allow"*) continue ;;
      esac
      matched="$(printf '%s\n' "$content" | grep -oE -- "$regex" | head -n1)"
      [ -n "$matched" ] || continue
      # shellcheck disable=SC2059
      printf '%s:%s: %s  [masked %s]\n' "${file#./}" "$lineno" "$name" "$(mask "$matched")"
      HIT=1
    done < <(grep -InE -- "$regex" "$file" 2>/dev/null || true)
  done
done

if (( HIT )); then
  echo "SECRET-SCAN: FAIL（发现疑似敏感信息，请移除并轮换凭据）" >&2
  exit 1
fi
echo "SECRET-SCAN: PASS（未发现敏感信息）"
exit 0
