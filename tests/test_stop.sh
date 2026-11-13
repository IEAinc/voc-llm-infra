#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
start() { bash "$BIN/pod-start.sh" "$@"; }
stop()  { bash "$BIN/pod-stop.sh" "$@"; }

t_stop_ok() {
  start
  # 가동 시간 계산 확인용: 생성 시각을 1시간 전으로 조작
  jq '.created_epoch -= 3600' "$VOC_HOME/state/current_pod" > "$T/cp" && mv "$T/cp" "$VOC_HOME/state/current_pod"
  stop || fail "stop should succeed"
  assert_eq "$(events)" "START:ok STOP:ok" "events"
  assert_eq "$(last .pod_id)" pod1 "pod_id"
  # jq 1.7 은 숫자 리터럴(1.00)을 그대로 출력하므로 값 비교는 jq 안에서 한다
  assert_eq "$(last '.uptime_hr == 1')" true "uptime_hr"
  assert_eq "$(last '.est_cost_usd == 0.59')" true "est_cost_usd"
  assert_eq "$(last '.uptime_hr|type')" number "uptime type"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 1 "deleted once"
  assert_file_has "$UPSTREAM_CONF" "return 503"
  assert_no_file "$VOC_HOME/state/current_pod"
}

t_stop_no_pod() {
  stop
  assert_eq "$(events)" "STOP:no_pod" "events"
  assert_file_has "$UPSTREAM_CONF" "return 503"
}

t_stop_delete_404_counts_as_deleted() {
  start
  FAKE_DELETE_RC=4 stop || fail "404 means already gone"
  assert_eq "$(last .result)" ok "result"
  assert_no_file "$VOC_HOME/state/current_pod"
}

t_stop_delete_fail_keeps_state() {
  start
  FAKE_DELETE_RC=1 stop && fail "should fail"
  assert_eq "$(last .result)" failed_delete "result"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 3 "3 attempts"
  assert_eq "$(calls_count 'SLEEP 30')" 2 "2 waits"
  assert_eq "$(calls_count 'NOTIFY STOP failed: pod not deleted')" 1 "notify"
  [ -f "$VOC_HOME/state/current_pod" ] || fail "current_pod must remain for retry"
}

t_stop_deletes_on_holiday() {
  start
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  stop
  assert_eq "$(events)" "START:ok STOP:ok" "events"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 1 "deleted on holiday"
  assert_no_file "$VOC_HOME/state/current_pod"
}

t_stop_deletes_orphan_created_pod() {
  start
  echo '{"id":"podX"}' > "$VOC_HOME/state/created.json"
  stop
  assert_eq "$(calls_count 'RP DELETE /pods/podX')" 1 "orphan deleted"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 1 "current deleted"
  assert_no_file "$VOC_HOME/state/created.json"
}

run_tests t_stop_ok t_stop_no_pod t_stop_delete_404_counts_as_deleted t_stop_delete_fail_keeps_state t_stop_deletes_on_holiday t_stop_deletes_orphan_created_pod
