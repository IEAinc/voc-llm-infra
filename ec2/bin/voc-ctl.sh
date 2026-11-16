#!/usr/bin/env bash
# 운영 일시정지/재개. GitHub Actions(aws_build_deploy)나 SSH 에서 root 로 실행한다.
#   voc-ctl.sh pause   : 실행 중인 Pod 를 내리고 08:30 자동 기동과 업무시간 감시를 멈춘다
#   voc-ctl.sh resume  : 일시정지를 풀고 실행 중인 Pod 를 내린다. 업무시간이면 새 Pod 를 띄운다
#   voc-ctl.sh status  : 일시정지 여부와 현재 Pod
# 18:00/19:30 종료 cron 은 일시정지 중에도 돈다(남은 Pod 정리 안전망).
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${VOC_HOME:-/opt/voc-llm}/state"

in_hours() {  # 평일 08:30~17:59 (공휴일은 pod-start.sh 가 거른다)
  local dow=${VOC_NOW_DOW:-$(date +%u)} hm=${VOC_NOW_HM:-$(date +%H%M)}
  [ "$dow" -le 5 ] && [ "$((10#$hm))" -ge 830 ] && [ "$((10#$hm))" -lt 1800 ]
}

case "${1:-}" in
  pause)
    touch "$STATE_DIR/paused"
    bash "$BIN/pod-stop.sh"
    echo "paused" ;;
  resume)
    bash "$BIN/pod-stop.sh"
    rm -f "$STATE_DIR/paused"
    if in_hours; then bash "$BIN/pod-start.sh"; echo "resumed: pod started"
    else echo "resumed: 다음 평일 08:30 에 기동"; fi ;;
  status)
    if [ -f "$STATE_DIR/paused" ]; then echo "state: paused"; else echo "state: active"; fi
    if [ -f "$STATE_DIR/current_pod" ]; then jq -c '{pod_id, gpu, endpoint}' "$STATE_DIR/current_pod"; else echo "pod: none"; fi ;;
  *) echo "사용법: $0 pause|resume|status" >&2; exit 2 ;;
esac
