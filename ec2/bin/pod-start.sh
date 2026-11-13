#!/usr/bin/env bash
# 평일 08:30 cron. 수동: pod-start.sh --force (공휴일 무시)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock 9

trigger=cron
if [ "${1:-}" = "--force" ]; then trigger=manual; fi

if [ "$trigger" = cron ] && is_holiday; then
  log_event START skipped_holiday
  exit 0
fi
if [ -f "$STATE_DIR/current_pod" ]; then
  log_event START already_running --arg pod_id "$(jq -r .pod_id "$STATE_DIR/current_pod")"
  exit 0
fi
do_start "$trigger"
