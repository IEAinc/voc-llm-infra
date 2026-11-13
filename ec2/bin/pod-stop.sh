#!/usr/bin/env bash
# 평일 18:00 cron. 수동: pod-stop.sh --force (공휴일 무시)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock 9

if [ "${1:-}" != "--force" ] && is_holiday; then
  log_event STOP skipped_holiday
  exit 0
fi
do_stop ok
