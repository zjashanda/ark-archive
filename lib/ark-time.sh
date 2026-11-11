#!/usr/bin/env bash
# ark-time.sh —— 北京时间无时区时间契约的 bash 入口。
#
# 用法（source 后调用）：
#   . "$(dirname "$0")/ark-time.sh"
#   ark_now                 # 2026-11-10 12:09:56
#   ark_stamp               # 20261110-120956
#   ark_normalize "$raw"    # 把任意时间规范化为契约格式
#   ark_check "$text"       # 契约格式返回 0，否则 1
#
# 约定：所有格式化都必须走这里，禁止脚本里自己写 date +"%Y-%m-%dT%H:%M:%SZ"。  # time-lint:allow 反例说明：这行在讲禁止什么
# 首选调用 lib/ark_time.py（唯一实现）；python 缺失时才退回 date 命令，
# 退路与主实现规则一致（固定 UTC+8，无时区后缀）。

ARK_TIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARK_TIME_ANCHOR="$(cd "$ARK_TIME_DIR/.." && pwd)"

_ark_python() {
    if [ -n "${ARK_PYTHON:-}" ] && command -v "$ARK_PYTHON" >/dev/null 2>&1; then
        printf '%s\n' "$ARK_PYTHON"
        return 0
    fi
    local candidate
    for candidate in python3 python py; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

_ark_time_py() {
    local python_bin
    python_bin="$(_ark_python)" || return 1
    "$python_bin" "$ARK_TIME_ANCHOR/lib/ark_time.py" "$@"
}

ark_now() {
    if _ark_time_py now 2>/dev/null; then
        return 0
    fi
    TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M:%S'
}

ark_stamp() {
    if _ark_time_py stamp 2>/dev/null; then
        return 0
    fi
    TZ=Asia/Shanghai date +'%Y%m%d-%H%M%S'
}

ark_normalize() {
    if [ $# -lt 1 ]; then
        echo "ark_normalize: 缺少时间参数" >&2
        return 2
    fi
    if _ark_time_py normalize "$1" 2>/dev/null; then
        return 0
    fi
    # 退路：仅处理已经合规的输入，其它格式一律报错而不是猜
    if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        printf '%s\n' "$1"
        return 0
    fi
    echo "ark_normalize: 无法解析时间: $1" >&2
    return 2
}

ark_check() {
    if [ $# -lt 1 ]; then
        return 2
    fi
    if _ark_time_py check "$1" 2>/dev/null; then
        return 0
    fi
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

# 直接执行时按命令行工具使用
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        now) shift; ark_now "$@" ;;
        stamp) shift; ark_stamp "$@" ;;
        normalize) shift; ark_normalize "$@" ;;
        check) shift; ark_check "$@" ;;
        *) echo "用法: ark-time.sh {now|stamp|normalize <时间>|check <时间>}" >&2; exit 2 ;;
    esac
fi
