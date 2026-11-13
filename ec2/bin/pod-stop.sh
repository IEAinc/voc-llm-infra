#!/usr/bin/env bash
# 평일 18:00 cron (+ 19:30 안전망). 공휴일에도 항상 실행한다(남은 Pod 삭제)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock 9

do_stop ok
