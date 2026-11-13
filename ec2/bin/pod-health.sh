#!/usr/bin/env bash
# 평일 09:00~17:58, 2분 간격 cron. 기동/복구 진행 중(잠금 보유)이면 이번 회차는 건너뛴다.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if is_holiday; then exit 0; fi
do_health
