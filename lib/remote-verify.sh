#!/usr/bin/env bash
# lib/remote-verify.sh —— 远端归档校验器（bash / PowerShell 两个入口共用的唯一实现）。
#
# 作用
#   在存储服务器上逐个重算 manifest.json 中 files[] 的 sha256 与字节数：
#     * 全部一致 —— 把暂存目录 move 成正式目录；若正式目录已存在，
#       先把旧目录移到隔离区 <quarantine>/<run_id>-replaced-<stamp>。
#     * 有任何不一致 —— 把暂存目录移到 <quarantine>/<run_id>-<stamp>，
#       打印 VERDICT=MISMATCH，返回 2。
#   manifest.json 缺失时同样视为 MISMATCH，返回 3。
#
# 用法
#   remote-verify.sh <stage> <target> <quarantine_root> <run_id> <stamp>
#     stage            已上传文件的暂存目录（manifest.json 位于其根部）
#     target           归档正式目录 <results-root>/<node>/<project>/<run_id>
#     quarantine_root  隔离区根目录
#     run_id           运行 ID
#     stamp            调用方生成的时间戳 YYYYMMDD_HHMMSS（北京时间，见 NOAH-43）
#
# 退出码
#   0  校验通过并成功落盘
#   2  哈希 / 大小不一致（VERDICT=MISMATCH）
#   3  manifest.json 缺失（VERDICT=MISMATCH）
#   4  参数错误
#   5  暂存目录 move 到正式目录失败
#   6  暂存目录 move 到隔离区失败
#
# 时间说明：本脚本不自行生成任何时间，时间戳由调用方按 NOAH-43 传入
# （北京时间、无时区后缀），因此远端无需依赖时区数据库。
set -uo pipefail

usage() {
  echo "用法: remote-verify.sh <stage> <target> <quarantine_root> <run_id> <stamp>" >&2
}

if [ "$#" -ne 5 ]; then
  usage
  exit 4
fi

stage=$1
target=$2
qroot=$3
runid=$4
stamp=$5

# stamp 必须是调用方按契约生成的 YYYYMMDD_HHMMSS，防止拼出诡异路径
case "$stamp" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "非法 stamp: $stamp" >&2; exit 4 ;;
esac

python3 - "$stage" <<'PY'
import hashlib, json, os, sys

stage = sys.argv[1]
mpath = os.path.join(stage, 'manifest.json')
if not os.path.exists(mpath):
    print('VERDICT=MISMATCH')
    print('REASON=manifest_missing')
    sys.exit(3)

try:
    man = json.load(open(mpath, encoding='utf-8'))
except Exception as exc:  # manifest 损坏同样按不一致处理
    print('VERDICT=MISMATCH')
    print('REASON=manifest_invalid')
    print('ERROR=%s' % exc)
    sys.exit(3)

bad, checked, nbytes = [], 0, 0
for f in man.get('files', []):
    p = os.path.join(stage, f['path'].replace('/', os.sep))
    if not os.path.isfile(p):
        bad.append('missing:' + f['path'])
        continue
    size = os.path.getsize(p)
    h = hashlib.sha256()
    with open(p, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    digest = h.hexdigest()
    checked += 1
    nbytes += size
    if size != int(f['bytes']):
        bad.append('size:%s manifest=%s remote=%s' % (f['path'], f['bytes'], size))
    if digest != f['sha256']:
        bad.append('sha256:%s manifest=%s remote=%s' % (f['path'], f['sha256'], digest))

print('CHECKED=%d' % checked)
print('BYTES=%d' % nbytes)
if bad:
    print('VERDICT=MISMATCH')
    print('MISMATCHES=%d' % len(bad))
    for b in bad[:50]:
        print('  ' + b)
    sys.exit(2)
print('VERDICT=OK')
PY
rc=$?

if [ "$rc" -eq 0 ]; then
  mkdir -p "$(dirname "$target")"
  if [ -d "$target" ]; then
    mkdir -p "$qroot"
    replaced="$qroot/${runid}-replaced-${stamp}"
    mv "$target" "$replaced" || { echo 'VERDICT=FAILED'; echo 'REASON=replace_move_failed'; exit 5; }
    echo "REPLACED_MOVED=$replaced"
  fi
  mv "$stage" "$target" || { echo 'VERDICT=FAILED'; echo 'REASON=move_failed'; exit 5; }
  # 目录 2775（setgid + rwxrwxr-x），文件保留可读写，禁止其它用户访问
  chmod -R u+rwX,g+rwX,o-rwx "$target" 2>/dev/null || true
  find "$target" -type d -exec chmod 2775 {} + 2>/dev/null || true
  chgrp -R sambashare "$target" 2>/dev/null || true
  echo "TARGET=$target"
  exit 0
fi

# 校验不通过：整体隔离，绝不落到正式目录
mkdir -p "$qroot"
mv "$stage" "$qroot/${runid}-${stamp}" || { echo 'VERDICT=FAILED'; echo 'REASON=quarantine_move_failed'; exit 6; }
echo "QUARANTINE=$qroot/${runid}-${stamp}"
exit "$rc"
