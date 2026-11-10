#!/usr/bin/env bash
# bin/ark-archive.sh —— 把一个运行结果目录归档到 ark 存储服务器（linux003）。
#
# 作用
#   复制（从不移动）源目录到：
#     <results-root>/<node>/<project>/<run_id>/
#   生成 manifest.json（run_id / project / device / node / result / started_at /
#   ended_at / files[path,bytes,sha256] / archived_at / source_dir），随后在远端
#   逐文件重算 sha256 校验。校验失败整体移入隔离区，绝不污染正式目录。
#
# 用法
#   export ARK_STORAGE_SSH_PASS='<口令>'        # 只引用变量名，脚本内不落明文
#   ./ark-archive.sh --source <目录> --project <项目> \
#                    [--run-id <id>] [--node <节点>] [--device <设备>] \
#                    [--result <PASS|FAIL|...>] [--host <主机>] [--port <端口>] \
#                    [--user <用户>] [--pass-env <变量名>] \
#                    [--results-root <目录>] [--quarantine-root <目录>] \
#                    [--legacy-rfc3339] [--dry-run]
#
#   暂存目录统一为 <results-root>/<node>/<project>/.incoming-<run_id>-<stamp>/，
#   bash 与 PowerShell 两个入口对同一棵源树生成完全相同的 files[].path。
#
# 退出码
#   0  成功（远端校验通过并已落盘）
#   2  用法 / 校验错误（缺参数、路径非法、缺口令环境变量、构建 manifest 失败）
#   3  远端哈希校验不一致（暂存目录已隔离）
#   4  传输失败（ssh / rsync / scp 失败，或远端 move 失败）
#   5  缺少依赖（ssh / scp / rsync / python3）
#
# 时间说明（NOAH-43）：manifest 中所有用户可见时间（started_at / ended_at /
# archived_at）一律为北京时间、格式 YYYY-MM-DD HH:MM:SS，无 T、无 Z、无时区偏移；
# 全部格式化都走 lib/ark_time.py（经 lib/ark-time.sh 或直接 import），脚本本身
# 不调用 date 自行拼接时间。--legacy-rfc3339 为已废弃的旧消费者兼容开关。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_SRC="$REPO_ROOT/lib/remote-verify.sh"

# 时间契约的 bash 入口（只做薄封装，唯一实现在 lib/ark_time.py）
# shellcheck source=../lib/ark-time.sh
. "$REPO_ROOT/lib/ark-time.sh"

SOURCE=""
PROJECT=""
RUN_ID=""
NODE="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
DEVICE=""
RESULT=""
STORAGE_HOST="${ARK_STORAGE_HOST:-10.11.63.24}"
STORAGE_PORT="${ARK_STORAGE_PORT:-10027}"
STORAGE_USER="${ARK_STORAGE_USER:-administrator}"
RESULTS_ROOT="/srv/storage/ark/results"
QUARANTINE_ROOT="/srv/storage/ark/_quarantine"
PASS_ENV="ARK_STORAGE_SSH_PASS"
DRY_RUN=0
LEGACY_RFC3339=0

usage() {
  cat <<'EOF'
用法:
  ark-archive.sh --source <目录> --project <项目> [选项]

必填:
  --source <目录>           要归档的结果目录（只复制，不移动）
  --project <名称>          项目名，落盘到 <results-root>/<项目>/<run_id>/

可选:
  --run-id <id>             默认取 --source 的末级目录名
  --node <节点>             默认取本机短主机名（小写）
  --device <设备>           默认等于 --node
  --result <PASS|FAIL|...>  默认按 summary_final.json 推导
  --host <主机>             SSH 主机，默认 10.11.63.24
  --port <端口>             SSH 端口，默认 10027
  --user <用户>             SSH 用户，默认 administrator
  --pass-env <变量名>       SSH 口令所在环境变量名，默认 ARK_STORAGE_SSH_PASS
  --results-root <目录>     默认 /srv/storage/ark/results
  --quarantine-root <目录>  默认 /srv/storage/ark/_quarantine
  --legacy-rfc3339          【已废弃】仅 archived_at 输出 +08:00 的 RFC3339
  --dry-run                 只构建并打印 manifest 与计划命令，不联网
  -h, --help                显示本帮助

退出码: 0 成功 | 2 用法/校验错误 | 3 远端哈希校验不一致 | 4 传输失败 | 5 缺少依赖
时间约定: 所有用户可见时间均为北京时间、无时区后缀（NOAH-43）。
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --node) NODE="${2:-}"; shift 2 ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --result) RESULT="${2:-}"; shift 2 ;;
    --host) STORAGE_HOST="${2:-}"; shift 2 ;;
    --port) STORAGE_PORT="${2:-}"; shift 2 ;;
    --user) STORAGE_USER="${2:-}"; shift 2 ;;
    --pass-env) PASS_ENV="${2:-}"; shift 2 ;;
    --results-root) RESULTS_ROOT="${2:-}"; shift 2 ;;
    --quarantine-root) QUARANTINE_ROOT="${2:-}"; shift 2 ;;
    --legacy-rfc3339) LEGACY_RFC3339=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "未知参数: $1" >&2; usage 2 ;;
  esac
done

[ -n "$SOURCE" ] || { echo "缺少 --source" >&2; usage 2; }
[ -n "$PROJECT" ] || { echo "缺少 --project" >&2; usage 2; }
[ -d "$SOURCE" ] || { echo "源路径不是目录: $SOURCE" >&2; exit 2; }
SOURCE="$(cd "$SOURCE" && pwd)"
[ -n "$RUN_ID" ] || RUN_ID="$(basename "$SOURCE")"
for v in "$PROJECT" "$RUN_ID" "$NODE"; do
  case "$v" in *[!A-Za-z0-9._-]*) echo "非法的路径片段: $v" >&2; exit 2 ;; esac
done
[ -n "$DEVICE" ] || DEVICE="$NODE"

[ -f "$VERIFY_SRC" ] || { echo "缺少远端校验器: $VERIFY_SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ark-archive.XXXXXX")"
ASKPASS=""
cleanup() {
  [ -n "$ASKPASS" ] && rm -f "$ASKPASS"
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------ manifest
# 唯一的时间格式化实现在 lib/ark_time.py：本段直接 import，绝不自行格式化时间。
set +e
BUILD_OUT="$(python3 - "$REPO_ROOT/lib" "$SOURCE" "$WORK/manifest.json" \
  "$RUN_ID" "$PROJECT" "$DEVICE" "$NODE" "$RESULT" "$LEGACY_RFC3339" <<'PY'
import datetime, hashlib, json, os, sys

lib_dir, src, out, run_id, project, device, node, result = sys.argv[1:9]
legacy = sys.argv[9] == '1'
sys.dont_write_bytecode = True  # 不在仓库 lib/ 下留下 __pycache__
sys.path.insert(0, lib_dir)
import ark_time


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


files = []
for root, dirs, names in os.walk(src):
    dirs.sort()
    for name in sorted(names):
        p = os.path.join(root, name)
        # 跳过符号链接与非常规文件（保留迁移前的行为）
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        rel = os.path.relpath(p, src).replace(os.sep, '/')
        files.append({'path': rel, 'bytes': os.path.getsize(p), 'sha256': sha256(p)})
if not files:
    sys.exit('源目录下没有任何文件: %s' % src)
# 与 PowerShell 入口保持完全一致的顺序（Ordinal 升序），便于逐字节比对清单
files.sort(key=lambda f: f['path'])

summary = {}
sp = os.path.join(src, 'summary_final.json')
if os.path.isfile(sp):
    try:
        summary = json.load(open(sp, encoding='utf-8'))
    except Exception:
        summary = {}
if not isinstance(summary, dict):
    summary = {}


def from_source(value):
    """返回 (契约格式时间, 原始来源字符串)；无法解析时第一项为 None。"""
    raw = '' if value is None else str(value).strip()
    if not raw:
        return None, ''
    try:
        return ark_time.to_text(raw), raw
    except Exception:
        return None, raw


started_at, raw_started = from_source(summary.get('started_at'))
ended_at, raw_ended = from_source(summary.get('ended_at'))


def mtime_iso(rel):
    ts = os.path.getmtime(os.path.join(src, rel))
    # 以北京时间表示 mtime，作为原始来源字符串；normalize 时仍是同一时刻
    return datetime.datetime.fromtimestamp(ts, ark_time.BEIJING).isoformat()


if started_at is None:
    earliest = min(files, key=lambda f: os.path.getmtime(os.path.join(src, f['path'])))
    raw_started = mtime_iso(earliest['path'])
    started_at = ark_time.to_text(raw_started)

if ended_at is None:
    latest = max(files, key=lambda f: os.path.getmtime(os.path.join(src, f['path'])))
    raw_ended = mtime_iso(latest['path'])
    ended_at = ark_time.to_text(raw_ended)

if not result:
    rate = None
    nw = summary.get('normal_window') or {}
    if isinstance(nw, dict) and nw.get('recognition_rate') is not None:
        rate = float(nw['recognition_rate'])
    elif summary.get('recognition_rate') is not None:
        rate = float(summary['recognition_rate'])
    if rate is not None:
        result = 'PASS' if rate >= 0.9 else 'FAIL'
    elif summary.get('status_counts'):
        result = '+'.join(summary['status_counts'].keys())
    else:
        result = 'unknown'

archived_at = ark_time.now_text()
if legacy:
    # 仅旧 ark-kb 消费者显式开启时使用；默认永不输出 RFC3339
    archived_at = ark_time.legacy_rfc3339(archived_at)

manifest = {
    'schema': 'manifest.v1',
    'run_id': run_id,
    'project': project,
    'device': device,
    'node': node,
    'result': result,
    'started_at': started_at,
    'ended_at': ended_at,
    'files': files,
    'archived_at': archived_at,
    'source_dir': src,
}
if raw_started:
    manifest['raw_started_at'] = raw_started
if raw_ended:
    manifest['raw_ended_at'] = raw_ended

json.dump(manifest, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('files=%d bytes=%d' % (len(files), sum(f['bytes'] for f in files)))
PY
)"
build_rc=$?
set -e
if [ "$build_rc" -ne 0 ]; then
  echo "构建 manifest 失败（rc=$build_rc）" >&2
  exit 2
fi
FILE_COUNT="${BUILD_OUT#files=}"
FILE_COUNT="${FILE_COUNT%% *}"

STAMP="$(ark_stamp)"
REMOTE="$STORAGE_USER@$STORAGE_HOST"
STAGE="$RESULTS_ROOT/$NODE/$PROJECT/.incoming-$RUN_ID-$STAMP"
TARGET="$RESULTS_ROOT/$NODE/$PROJECT/$RUN_ID"
REMOTE_VERIFY="$RESULTS_ROOT/.verify-$RUN_ID-$STAMP.sh"

echo "源目录      : $SOURCE"
echo "目标目录    : $TARGET"
echo "节点 / 设备 : $NODE / $DEVICE"
echo "文件 / 字节 : $BUILD_OUT"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- 文件清单 ---"
  python3 - "$WORK/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
print('  result     : %s' % m['result'])
print('  time       : %s -> %s' % (m['started_at'], m['ended_at']))
if 'raw_started_at' in m:
    print('  raw time   : %s -> %s' % (m.get('raw_started_at'), m.get('raw_ended_at')))
for f in m['files']:
    print('  %-45s %12d %s' % (f['path'], f['bytes'], f['sha256']))
PY
  echo "--- manifest.json（预览）---"
  cat "$WORK/manifest.json"
  echo
  echo "--- 计划执行的远端命令（--dry-run，不执行）---"
  echo "  # 认证：sshpass -e（可用时）或一次性 askpass 脚本；口令只来自环境变量 $PASS_ENV"
  cat <<EOF
  ssh -n -p $STORAGE_PORT $REMOTE "mkdir -p '$STAGE' && rm -f '$REMOTE_VERIFY'"
  rsync -az --info=stats2 -e "ssh -p $STORAGE_PORT -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10" "$SOURCE/" "$REMOTE:$STAGE/"
  scp -P $STORAGE_PORT -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR "$WORK/manifest.json" "$REMOTE:$STAGE/manifest.json"
  scp -P $STORAGE_PORT -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR "$VERIFY_SRC" "$REMOTE:$REMOTE_VERIFY"
  ssh -n -p $STORAGE_PORT $REMOTE "bash '$REMOTE_VERIFY' '$STAGE' '$TARGET' '$QUARANTINE_ROOT/$NODE' '$RUN_ID' '$STAMP'; rc=\$?; rm -f '$REMOTE_VERIFY'; exit \$rc"
EOF
  echo "[dry-run] 未复制任何文件，未建立任何连接"
  exit 0
fi

# -------------------------------------------------------------------- 依赖
for tool in ssh scp rsync python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少依赖: $tool" >&2; exit 5; }
done

# -------------------------------------------------------------------- 认证
PW="${!PASS_ENV:-}"
if [ -z "$PW" ]; then
  echo "缺少 SSH 口令：请先设置环境变量 $PASS_ENV" >&2
  exit 2
fi
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10)
if command -v sshpass >/dev/null 2>&1; then
  export SSHPASS="$PW"
  SSH_BIN=(sshpass -e ssh)
  SCP_BIN=(sshpass -e scp)
  RSYNC_SSH="sshpass -e ssh -p $STORAGE_PORT -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10"
else
  ASKPASS="$WORK/askpass.sh"
  printf '#!/bin/sh\nprintf %%s "$ARK_ASKPASS_VALUE"\n' >"$ASKPASS"
  chmod 700 "$ASKPASS"
  export ARK_ASKPASS_VALUE="$PW" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
  SSH_BIN=(ssh)
  SCP_BIN=(scp)
  RSYNC_SSH="ssh -p $STORAGE_PORT -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10"
fi
unset PW

# -------------------------------------------------------------------- 上传
echo "[1/5] mkdir remote staging"
if ! "${SSH_BIN[@]}" -n -p "$STORAGE_PORT" "${SSH_OPTS[@]}" "$REMOTE" \
  "mkdir -p '$STAGE' && rm -f '$REMOTE_VERIFY'"; then
  echo "远端创建暂存目录失败" >&2
  exit 4
fi

echo "[2/5] upload $FILE_COUNT files"
if ! rsync -az --info=stats2 -e "$RSYNC_SSH" "$SOURCE/" "$REMOTE:$STAGE/"; then
  echo "rsync 上传失败" >&2
  exit 4
fi

echo "[3/5] upload manifest + verifier"
if ! "${SCP_BIN[@]}" -P "$STORAGE_PORT" "${SSH_OPTS[@]}" \
  "$WORK/manifest.json" "$REMOTE:$STAGE/manifest.json" >/dev/null; then
  echo "manifest 上传失败" >&2
  exit 4
fi
if ! "${SCP_BIN[@]}" -P "$STORAGE_PORT" "${SSH_OPTS[@]}" \
  "$VERIFY_SRC" "$REMOTE:$REMOTE_VERIFY" >/dev/null; then
  echo "校验器上传失败" >&2
  exit 4
fi

# -------------------------------------------------------------------- 远端校验
echo "[4/5] remote sha256 verification"
set +e
"${SSH_BIN[@]}" -n -p "$STORAGE_PORT" "${SSH_OPTS[@]}" "$REMOTE" \
  "bash '$REMOTE_VERIFY' '$STAGE' '$TARGET' '$QUARANTINE_ROOT/$NODE' '$RUN_ID' '$STAMP'; rc=\$?; rm -f '$REMOTE_VERIFY'; exit \$rc"
rc=$?
set -e
echo "[5/5] exit=$rc"
case "$rc" in
  0)
    echo "ARCHIVE_OK"
    ;;
  2|3)
    echo "远端哈希校验不一致（rc=$rc），暂存目录已隔离" >&2
    exit 3
    ;;
  *)
    echo "归档失败（远端 rc=$rc）" >&2
    exit 4
    ;;
esac
