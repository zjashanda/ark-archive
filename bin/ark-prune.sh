#!/usr/bin/env bash
# ark-prune.sh —— /srv/storage/ark/results 的保留期清理工具（北京时间，无时区后缀）。
#
# 保留策略（已确认，方案 B，数字不可更改）：
#   summary_final.*、rounds.csv、receipt、manifest.json 等摘要/证据文件 —— 永久保留
#   */serial_logs/* 下的串口日志 —— 超过 30 天后删除
#   */tool.log 工具日志 —— 超过 90 天后删除
#
# 白名单（核心安全属性，任何参数组合下都不得突破）：
#   只有同时满足以下两个路径模式之一的普通文件才可能成为候选：
#     */serial_logs/*   任意层级的 serial_logs 目录下的文件
#     */tool.log        任意层级、文件名恰为 tool.log 的文件
#   白名单之外的任何文件永远不会被本脚本删除。find 只在 $ROOT 内匹配，
#   -type f 天然排除符号链接和目录；删除时逐个 rm 白名单内的具体文件，
#   绝不对计算出来的父目录执行 rm -rf。
#
# 默认是预演（dry-run）：只打印将被删除的文件、大小、契约格式的 mtime
# 以及合计数量和可释放字节数，不删除任何东西。只有显式传 --apply 才删除。
#
# 用法：
#   ./ark-prune.sh --root <dir> [--serial-days 30] [--tool-days 90] [--apply] [--yes]
#   ./ark-prune.sh --root /srv/storage/ark/results                 # 预演
#   ./ark-prune.sh --root /srv/storage/ark/results --apply         # 删除前询问 yes
#   ./ark-prune.sh --root /srv/storage/ark/results --apply --yes   # 免交互（cron）
#
# 退出码：
#   0  成功（包括"没有可清理的文件"）
#   1  确认提示处输入的不是 yes，已中止
#   2  用法/参数错误：缺少或非法 --root、天数不是正整数、在过宽的根目录上运行
#   5  根目录不存在，或不是目录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ark-time.sh
. "$SCRIPT_DIR/../lib/ark-time.sh"

ROOT=""
SERIAL_DAYS=30
TOOL_DAYS=90
APPLY=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
用法：
  ark-prune.sh --root <dir> [--serial-days 30] [--tool-days 90] [--apply] [--yes]

  --root <dir>        必填，结果根目录（例如 /srv/storage/ark/results）
  --serial-days <n>   serial_logs 保留天数，正整数，默认 30
  --tool-days <n>     tool.log 保留天数，正整数，默认 90
  --apply             真正执行删除（默认只预演）
  --yes, -y           跳过交互确认，仅配合 --apply 使用
  -h, --help          显示本帮助

退出码：0 成功；1 用户中止；2 用法/参数错误；5 根目录不存在或不是目录
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --serial-days) SERIAL_DAYS="${2:-}"; shift 2 ;;
    --tool-days) TOOL_DAYS="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

# ---------------------------------------------------------------- 参数校验
if [ -z "$ROOT" ]; then
  echo "错误：缺少必填参数 --root" >&2
  exit 2
fi
if ! is_positive_int "$SERIAL_DAYS"; then
  echo "错误：--serial-days 必须是正整数，收到: $SERIAL_DAYS" >&2
  exit 2
fi
if ! is_positive_int "$TOOL_DAYS"; then
  echo "错误：--tool-days 必须是正整数，收到: $TOOL_DAYS" >&2
  exit 2
fi

# 先做字面量判断：即使这些目录当前不存在也要明确拒绝，而不是落到 exit 5
ROOT_LEX="${ROOT%/}"
[ -n "$ROOT_LEX" ] || ROOT_LEX="/"
case "$ROOT_LEX" in
  /|/srv|/srv/storage|/srv/storage/ark)
    echo "错误：拒绝在过宽的根目录上运行: $ROOT_LEX（会波及其他数据），请指定具体结果目录" >&2
    exit 2
    ;;
esac

if [ ! -e "$ROOT" ]; then
  echo "错误：根目录不存在: $ROOT" >&2
  exit 5
fi
if [ ! -d "$ROOT" ]; then
  echo "错误：根路径不是目录: $ROOT" >&2
  exit 5
fi

# 解析符号链接后再判断，避免用软链接绕过下面的过宽目录检查
ROOT_REAL="$(cd "$ROOT" 2>/dev/null && pwd -P)" || {
  echo "错误：无法进入根目录: $ROOT" >&2
  exit 5
}

case "$ROOT_REAL" in
  /|/srv|/srv/storage|/srv/storage/ark)
    echo "错误：拒绝在过宽的根目录上运行: $ROOT_REAL（会波及其他数据），请指定具体结果目录" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------- 收集候选
# 只有下面两条 find 会产生候选；不允许增加任何其它模式。
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT

find "$ROOT_REAL" -path '*/serial_logs/*' -type f -mtime +"$SERIAL_DAYS" -print >>"$LIST"
find "$ROOT_REAL" -path '*/tool.log' -type f -mtime +"$TOOL_DAYS" -print >>"$LIST"
# serial_logs/tool.log 会同时命中两条规则，去重后再统计
sort -u -o "$LIST" "$LIST"

COUNT=$(wc -l <"$LIST" | tr -d ' ')
BYTES=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  BYTES=$((BYTES + $(stat -c %s -- "$f" 2>/dev/null || echo 0)))
done <"$LIST"

MIB=$(awk -v b="$BYTES" 'BEGIN { printf "%.1f", b / 1048576 }')

echo "root      : $ROOT_REAL"
echo "policy    : serial_logs > ${SERIAL_DAYS}d, tool.log > ${TOOL_DAYS}d, everything else kept"
echo "candidates: $COUNT files, $BYTES bytes (${MIB} MiB)"

# 无论是否 --apply，先把每个候选的大小和契约格式 mtime 全部打印出来
if [ "$COUNT" -gt 0 ]; then
  echo "--- candidates ---"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    size=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
    mtime_raw=$(stat -c %Y -- "$f" 2>/dev/null || echo 0)
    # 所有展示时间都必须走 ark_normalize，禁止在此处内联格式化
    mtime="$(ark_normalize "$mtime_raw" 2>/dev/null)" || mtime="(时间不可用)"
    printf '%12s  %s  %s\n' "$size" "$mtime" "$f"
  done <"$LIST"
fi

if [ "$APPLY" -eq 0 ]; then
  echo "[dry-run] nothing deleted; pass --apply to delete"
  exit 0
fi

if [ "$COUNT" -eq 0 ]; then
  echo "nothing to prune"
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf 'delete %s files (%s bytes, %s MiB)? [yes/N] ' "$COUNT" "$BYTES" "$MIB"
  answer=""
  read -r answer || answer=""
  if [ "$answer" != "yes" ]; then
    echo "aborted"
    exit 1
  fi
fi

# 只删除上面列表里逐个列出的白名单文件，绝不删除目录
DELETED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if rm -f -- "$f"; then
    DELETED=$((DELETED + 1))
  fi
done <"$LIST"
echo "deleted $DELETED files"
