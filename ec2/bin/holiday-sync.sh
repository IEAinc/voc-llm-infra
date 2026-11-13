#!/usr/bin/env bash
# 매주 월요일 07:00 cron + install.sh 에서 1회. 수동 재실행 가능.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
do_holiday_sync
