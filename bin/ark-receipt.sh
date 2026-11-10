#!/usr/bin/env bash
# ark-receipt.sh —— 归档完成后生成 run.receipt.v1 回执并回传存储服务器（Linux / macOS / Git Bash）
# 时间契约：所有用户可见时间一律北京时间无时区 YYYY-MM-DD HH:MM:SS（lib/ark_time.py 唯一实现）。
#
# 用法：
#   ark-receipt.sh --node win009 --project tcl-r5 --run-id 20261102_090644_wake_recognition --upload
#   ark-receipt.sh --node win009 --project tcl-r5 --run-id ... --task "…" --skill lstest --dry-run
#   ark-receipt.sh --node win009 --project tcl-r5 --run-id ... --legacy-rfc3339   # 旧 ark-kb 兼容
#
# 做的事：
#   1. 定位存储上的归档目录 <storage>/results/<node>/<project>/<run_id>
#      （本机有就本地读，没有就 ssh 取 manifest.json + summary_final.json）
#   2. 调同目录 ark_receipt.py 生成回执，evidence_dir 固定写存储路径
#   3. --upload 时回传 <storage>/receipts/<node>/<project>/<run_id>/run.receipt.json，
#      并在远端重算 sha256 读回比对（不一致即失败，绝不静默跳过）
#
# 参数：
#   --node --project --run-id   必填
#   --upload                    回传到存储服务器并在远端校验
#   --dry-run                   只生成不落盘（回执 JSON 打到 stdout）
#   --storage-root <路径>       存储根，默认 /srv/storage/ark
#   其余未知参数原样透传给 ark_receipt.py
#   （--task --skill --skill-version --firmware --platform --confidence
#     --lessons --bugs --tags --out --no-local-verify --legacy-rfc3339 --tz-offset）
#
# 环境变量（全部可选，缺省即本工作区默认）：
#   ARK_STORAGE_HOST / ARK_STORAGE_PORT / ARK_STORAGE_USER / ARK_STORAGE_ROOT
#   ARK_STORAGE_SSH_PASS —— 只在需要密码登录时读取，不落盘、不打印（脚本只引用变量名）
#
# 退出码：
#   0 成功；2 参数/输入错误；3 哈希不符；4 传输失败；5 缺少 python3/依赖

set -euo pipefail

HOST="${ARK_STORAGE_HOST:-10.11.63.24}"
PORT="${ARK_STORAGE_PORT:-10027}"
USER_NAME="${ARK_STORAGE_USER:-administrator}"
ROOT="${ARK_STORAGE_ROOT:-/srv/storage/ark}"

NODE=""; PROJECT=""; RUN_ID=""
UPLOAD=0; DRY=0; PASSTHRU=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --run-id) RUN_ID="$2"; shift 2;;
    --upload) UPLOAD=1; shift;;
    --dry-run) DRY=1; PASSTHRU+=(--dry-run); shift;;
    --storage-root) ROOT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) PASSTHRU+=("$1"); shift;;
  esac
done

[[ -n "$NODE" && -n "$PROJECT" && -n "$RUN_ID" ]] || { echo "ERROR: --node --project --run-id 必填" >&2; exit 2; }
[[ -f "$SCRIPT_DIR/ark_receipt.py" ]] || { echo "ERROR: 同目录缺 ark_receipt.py" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: 缺少 python3（回执生成依赖 Python 3.6+）" >&2; exit 5; }

RESULTS_DIR="$ROOT/results/$NODE/$PROJECT/$RUN_ID"
RECEIPTS_DIR="$ROOT/receipts/$NODE/$PROJECT/$RUN_ID"

# --- ssh/scp 封装：优先免密，其次 sshpass -e（密码只从环境变量来） -----------------
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
REMOTE="$USER_NAME@$HOST"

have_key_auth() {
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o PasswordAuthentication=no -p "$PORT" "$REMOTE" true >/dev/null 2>&1
}

if have_key_auth; then
  rsh() { ssh "${SSH_OPTS[@]}" -p "$PORT" "$REMOTE" "$@"; }
  rcp_from() { scp "${SSH_OPTS[@]}" -P "$PORT" -q "$REMOTE:$1" "$2"; }
  rcp_to() { scp "${SSH_OPTS[@]}" -P "$PORT" -q "$1" "$REMOTE:$2"; }
else
  [[ -n "${ARK_STORAGE_SSH_PASS:-}" ]] || { echo "ERROR: 免密不可用且未设置 ARK_STORAGE_SSH_PASS" >&2; exit 4; }
  command -v sshpass >/dev/null || { echo "ERROR: 未安装 sshpass" >&2; exit 4; }
  export SSHPASS="$ARK_STORAGE_SSH_PASS"
  rsh() { sshpass -e ssh "${SSH_OPTS[@]}" -p "$PORT" "$REMOTE" "$@"; }
  rcp_from() { sshpass -e scp "${SSH_OPTS[@]}" -P "$PORT" -q "$REMOTE:$1" "$2"; }
  rcp_to() { sshpass -e scp "${SSH_OPTS[@]}" -P "$PORT" -q "$1" "$REMOTE:$2"; }
fi

# 存储目录按节点自建：普通用户建不了时，用同一把管理密码 sudo 一次性建好，
# 之后目录是 2775（组 sambashare 可写），后续归档不再需要提权。
ensure_dir() {
  local path="$1"
  shift
  if rsh "mkdir -p '$path'" 2>/dev/null; then return 0; fi
  [[ -z "${ARK_STORAGE_SSH_PASS:-}" ]] && return 1
  export SSHPASS="${ARK_STORAGE_SSH_PASS}"
  local fix="" d
  for d in "$path" "$@"; do fix="$fix '$d'"; done
  echo "PROVISION: mkdir -p $path 需要提权，用 sudo 自建（组 sambashare 可写）" >&2
  printf '%s\n' "$ARK_STORAGE_SSH_PASS" | sshpass -e ssh "${SSH_OPTS[@]}" -p "$PORT" "$REMOTE" \
    "sudo -S -p '' sh -c \"mkdir -p '$path' && for d in $fix; do chgrp sambashare \\\"\\\$d\\\"; chmod 2775 \\\"\\\$d\\\"; done\"" || return 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -f "$RESULTS_DIR/manifest.json" ]]; then
  MANIFEST="$RESULTS_DIR/manifest.json"
  SUMMARY="$RESULTS_DIR/summary_final.json"
  echo "SOURCE: local $RESULTS_DIR"
else
  echo "SOURCE: remote $REMOTE:$RESULTS_DIR"
  rcp_from "$RESULTS_DIR/manifest.json" "$WORK/manifest.json" || { echo "ERROR: 取 manifest.json 失败" >&2; exit 4; }
  rcp_from "$RESULTS_DIR/summary_final.json" "$WORK/summary_final.json" || echo "WARN: 没有 summary_final.json，回执按 manifest 生成" >&2
  MANIFEST="$WORK/manifest.json"
  SUMMARY="$WORK/summary_final.json"
fi

ARGS=(--manifest "$MANIFEST" --node "$NODE" --project "$PROJECT" --run-id "$RUN_ID"
      --storage-root "$ROOT" --evidence-dir "$RESULTS_DIR" --out "$WORK/run.receipt.json")
if [[ -f "$SUMMARY" ]]; then ARGS+=(--summary "$SUMMARY"); fi
if [[ ${#PASSTHRU[@]} -gt 0 ]]; then ARGS+=("${PASSTHRU[@]}"); fi

python3 "$SCRIPT_DIR/ark_receipt.py" "${ARGS[@]}"

LOCAL_RECEIPT="$WORK/run.receipt.json"

if [[ $DRY -eq 1 ]]; then
  echo "UPLOAD: skipped（--dry-run）"
  exit 0
elif [[ $UPLOAD -eq 0 ]]; then
  cp "$LOCAL_RECEIPT" "./run.receipt.json"
  echo "UPLOAD: skipped（未加 --upload）；本地副本 ./run.receipt.json"
  exit 0
fi

LOCAL_SHA="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LOCAL_RECEIPT")"

if [[ -d "$ROOT/receipts" ]]; then
  mkdir -p "$RECEIPTS_DIR"
  cp "$LOCAL_RECEIPT" "$RECEIPTS_DIR/run.receipt.json"
  REMOTE_SHA="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$RECEIPTS_DIR/run.receipt.json")"
  WHERE="local $RECEIPTS_DIR/run.receipt.json"
else
  ensure_dir "$RECEIPTS_DIR" "$ROOT/receipts/$NODE" "$ROOT/receipts/$NODE/$PROJECT" || { echo "ERROR: 建 receipts 目录失败" >&2; exit 4; }
  rcp_to "$LOCAL_RECEIPT" "$RECEIPTS_DIR/run.receipt.json" || { echo "ERROR: 回传回执失败" >&2; exit 4; }
  REMOTE_SHA="$(rsh "sha256sum '$RECEIPTS_DIR/run.receipt.json' | cut -d' ' -f1" | tr -d '\r')"
  WHERE="remote $REMOTE:$RECEIPTS_DIR/run.receipt.json"
fi

[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || { echo "ERROR: 回执回传哈希不一致 local=$LOCAL_SHA remote=$REMOTE_SHA" >&2; exit 3; }
echo "RECEIPT_AT: $WHERE"
echo "RECEIPT_SHA256: $REMOTE_SHA"
echo "RECEIPT_VERIFIED: OK"
