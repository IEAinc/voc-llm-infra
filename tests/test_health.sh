#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
start()  { bash "$BIN/pod-start.sh" "$@"; }
health() { bash "$BIN/pod-health.sh"; }

t_health_ok_logs_nothing() {
  start
  health
  assert_eq "$(events)" "START:ok" "no health log when healthy"
  assert_eq "$(cat "$VOC_HOME/state/health_fail")" 0 "fail count"
}

t_health_degraded_then_self_recovered() {
  start
  FAKE_VLLM_CODE=000 health
  assert_eq "$(last .result)" degraded "first failure"
  assert_eq "$(last .check)" B "check B"
  health
  assert_eq "$(events)" "START:ok HEALTH:degraded HEALTH:recovered_self" "events"
  assert_eq "$(calls_count 'NOTIFY')" 0 "no notify before down"
}

t_health_down_check_b_replaces_pod() {
  start
  export FAKE_VLLM_BAD_HOST=pod1-8000.proxy.runpod.net
  health; health
  assert_eq "$(events)" "START:ok HEALTH:degraded" "two failures, not yet down"
  health
  assert_eq "$(events)" "START:ok HEALTH:degraded HEALTH:down STOP:replaced START:ok" "events"
  assert_eq "$(jq -r .pod_id "$VOC_HOME/state/current_pod")" pod2 "new pod"
  assert_eq "$(last .trigger)" health "trigger"
  assert_file_has "$UPSTREAM_CONF" "proxy_pass https://pod2-8000.proxy.runpod.net;"
  assert_eq "$(calls_count 'NOTIFY RunPod DOWN')" 1 "down notify"
  assert_eq "$(calls_count 'NOTIFY RunPod recovered')" 1 "recovered notify"
  assert_eq "$(cat "$VOC_HOME/state/recover_20261116")" 1 "recover count"
}

t_health_down_check_a_immediate() {
  start
  FAKE_POD_STATUS=EXITED health
  assert_eq "$(events)" "START:ok HEALTH:down STOP:replaced START:ok" "events"
  local down; down=$(jq -c 'select(.result=="down")' "$LOG_FILE")
  assert_eq "$(jq -r .check <<<"$down")" A "check A"
  assert_eq "$(jq -r .detail <<<"$down")" "pod status EXITED" "detail"
}

t_health_pod_404_is_down() {
  start
  FAKE_POD_STATUS=GONE health
  assert_eq "$(jq -r 'select(.result=="down")|.detail' "$LOG_FILE")" "pod status NOT_FOUND" "detail"
}

t_health_runpod_api_down_uses_check_b_only() {
  start
  FAKE_POD_STATUS=APIDOWN health
  assert_eq "$(events)" "START:ok" "vLLM ok, API down → healthy"
}

t_health_no_pod_triggers_start() {
  health
  assert_eq "$(events)" "HEALTH:no_pod START:ok" "events"
  assert_eq "$(last .trigger)" health "trigger"
}

t_health_gives_up_after_3_recoveries() {
  start
  export FAKE_POD_STATUS=GONE FAKE_VLLM_CODE=000
  health; health; health
  assert_eq "$(cat "$VOC_HOME/state/recover_20261116")" 3 "3 recoveries"
  health
  assert_eq "$(last .result)" gave_up "gave up on 4th"
  local n; n=$(wc -l < "$LOG_FILE")
  health
  assert_eq "$(wc -l < "$LOG_FILE")" "$n" "silent after gave_up"
  assert_eq "$(calls_count 'NOTIFY RunPod recovery gave up')" 1 "gave up notify once"
  assert_eq "$(calls_count 'NOTIFY RunPod recovery failed')" 3 "3 failed recoveries"
  # 운영자 수동 기동 → 카운터 초기화
  unset FAKE_VLLM_CODE
  start --force || fail "manual start"
  assert_no_file "$VOC_HOME/state/gave_up_20261116"
}

t_health_maintenance_skips() {
  start
  touch "$VOC_HOME/state/maintenance"
  FAKE_POD_STATUS=GONE health
  assert_eq "$(events)" "START:ok" "no action in maintenance"
}

t_health_holiday_skips() {
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  health
  assert_eq "$(events)" "" "no log on holiday"
  assert_eq "$(calls_count 'RP ')" 0 "no calls"
}

t_health_skips_when_locked() {
  start
  flock "$LOCK_FILE" sleep 2 &
  sleep 0.3
  FAKE_POD_STATUS=GONE health
  wait
  assert_eq "$(events)" "START:ok" "skipped while locked"
}

run_tests t_health_ok_logs_nothing t_health_degraded_then_self_recovered t_health_down_check_b_replaces_pod \
  t_health_down_check_a_immediate t_health_pod_404_is_down t_health_runpod_api_down_uses_check_b_only \
  t_health_no_pod_triggers_start t_health_gives_up_after_3_recoveries t_health_maintenance_skips \
  t_health_holiday_skips t_health_skips_when_locked
