#!/usr/bin/env bash
# 운영 제어. GitHub Actions(aws_build_deploy), cron, SSH 에서 root 로 실행한다.
#   voc-ctl.sh pause    : 실행 중인 Pod 를 내리고 08:30 자동 기동과 업무시간 감시를 멈춘다
#   voc-ctl.sh resume   : 일시정지를 풀고 실행 중인 Pod 를 내린다. 업무시간이면 새 Pod 를 띄운다
#   voc-ctl.sh status   : 일시정지 여부와 현재 Pod
#   voc-ctl.sh boot     : EC2 부팅 직후(cron @reboot). 감시를 켜고, 업무시간이면 Pod 를 띄운다
#   voc-ctl.sh shutdown : 업무시간 밖이면 Pod 를 내리고 감시를 끈 뒤 EC2 를 끈다(cron 18:10).
#                         Pod 삭제에 실패하면 과금 방지를 위해 EC2 를 끄지 않는다(19:30 재시도)
# 업무시간 = 평일 08:30~17:59. 공휴일·일시정지는 pod-start.sh 가 거른다.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$BIN/lib.sh"
POWEROFF=${VOC_POWEROFF:-shutdown -h +1}

in_hours() {
  local dow=${VOC_NOW_DOW:-$(date +%u)} hm=${VOC_NOW_HM:-$(date +%H%M)}
  [ "$dow" -le 5 ] && [ "$((10#$hm))" -ge 830 ] && [ "$((10#$hm))" -lt 1800 ]
}

# 꺼져 있는 밤사이 외부 접속 감시·Agent 누락 알람이 울리지 않도록 끄고 켠다.
# HEALTH_CHECK_ID 가 없으면(테스트, 모니터링 미구성) 건너뛴다.
alarm_names() { aws cloudwatch describe-alarms --region "$1" --alarm-name-prefix voc-llm- \
  --query 'MetricAlarms[].AlarmName' --output text; }
monitor_off() {
  [ -n "${HEALTH_CHECK_ID:-}" ] || return 0
  local r names
  for r in ap-northeast-2 us-east-1; do
    names=$(alarm_names "$r") && [ -n "$names" ] && aws cloudwatch disable-alarm-actions --region "$r" --alarm-names $names || true
  done
  aws route53 update-health-check --health-check-id "$HEALTH_CHECK_ID" --disabled >/dev/null || true
}
monitor_on() {  # 알람이 ALARM 에서 벗어난 뒤 알림을 켠다(아침마다 OK 메일 방지). 최대 20분 대기 후 모두 켠다
  [ -n "${HEALTH_CHECK_ID:-}" ] || return 0
  aws route53 update-health-check --health-check-id "$HEALTH_CHECK_ID" --no-disabled >/dev/null || true
  local r names i
  for i in $(seq 1 40); do
    names=$(aws cloudwatch describe-alarms --region ap-northeast-2 --alarm-name-prefix voc-llm- --state-value ALARM \
      --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null || echo x)
    [ -z "$names" ] && break
    sleep 30
  done
  for r in ap-northeast-2 us-east-1; do
    names=$(alarm_names "$r") && [ -n "$names" ] && aws cloudwatch enable-alarm-actions --region "$r" --alarm-names $names || true
  done
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
  boot)
    ( monitor_on >/dev/null 2>&1 & )
    if in_hours; then bash "$BIN/pod-start.sh"; fi ;;
  shutdown)
    if in_hours; then echo "업무시간이라 EC2 를 끄지 않습니다"; exit 0; fi
    bash "$BIN/pod-stop.sh" || true
    if [ -f "$STATE_DIR/current_pod" ]; then
      notify "EC2 shutdown skipped" "Pod $(jq -r .pod_id "$STATE_DIR/current_pod") 삭제에 실패해 EC2 를 끄지 않았습니다. RunPod 콘솔에서 Pod 를 직접 삭제하세요."
      exit 1
    fi
    monitor_off
    eval "$POWEROFF"
    echo "EC2 shutdown scheduled" ;;
  *) echo "사용법: $0 pause|resume|status|boot|shutdown" >&2; exit 2 ;;
esac
