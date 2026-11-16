#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
start() { bash "$BIN/pod-start.sh" "$@"; }

t_start_ok() {
  start || fail "pod-start should succeed"
  assert_eq "$(events)" "START:ok" "events"
  assert_eq "$(last .pod_id)" pod1 "pod_id"
  assert_eq "$(last .gpu)" "NVIDIA RTX A6000" "gpu"
  assert_eq "$(last .datacenter)" EU-RO-1 "datacenter"
  assert_eq "$(last .retries)" 0 "retries"
  assert_eq "$(last .cost_per_hr)" 0.59 "cost"
  assert_eq "$(last .model)" org/test-model "model"
  assert_eq "$(last .endpoint)" "https://pod1-8000.proxy.runpod.net" "endpoint"
  assert_file_has "$UPSTREAM_CONF" "proxy_pass https://pod1-8000.proxy.runpod.net;"
  assert_eq "$(jq -r .pod_id "$VOC_HOME/state/current_pod")" pod1 "state pod_id"
  assert_eq "$(jq -r '.created_epoch|type' "$VOC_HOME/state/current_pod")" number "created_epoch type"
}

t_start_retry_then_ok() {
  FAKE_CREATE_FAILS=2 start || fail "should succeed on 3rd attempt"
  assert_eq "$(last .result)" ok "result"
  assert_eq "$(last .retries)" 2 "retries"
  assert_eq "$(last .pod_id)" pod3 "pod_id"
  assert_eq "$(calls_count 'SLEEP 600')" 2 "retry waits"
}

t_start_no_gpu() {
  FAKE_CREATE_FAILS=99 start && fail "should fail"
  assert_eq "$(events)" "START:failed_no_gpu" "events"
  assert_eq "$(last .retries)" 3 "attempts"
  assert_eq "$(calls_count 'NOTIFY START failed: no GPU')" 1 "notify"
  assert_file_has "$UPSTREAM_CONF" "return 503"
  assert_no_file "$VOC_HOME/state/current_pod"
}

t_start_not_ready_deletes_pod() {
  FAKE_VLLM_CODE=000 start && fail "should fail"
  assert_eq "$(events)" "START:failed_not_ready" "events"
  assert_eq "$(last .pod_id)" pod1 "pod_id"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 1 "pod deleted"
  assert_eq "$(calls_count 'NOTIFY START failed: vLLM not ready')" 1 "notify"
  assert_no_file "$VOC_HOME/state/current_pod"
}

t_start_not_ready_counts_slow_checks() {
  FAKE_VLLM_CODE=000 FAKE_VLLM_DELAY=20 start && fail "should fail"
  assert_eq "$(events)" "START:failed_not_ready" "events"
  [ "$(calls_count 'VLLM ')" -le 3 ] || fail "too many vllm checks: $(calls_count 'VLLM ')"
  [ "$(last .waited_sec)" -ge 60 ] || fail "waited_sec $(last .waited_sec) < 60"
}

t_start_abort_deletes_pod() {
  FAKE_ABORT_AFTER_CREATE=1 start && fail "should abort"
  assert_eq "$(last .result)" failed_aborted "result"
  assert_eq "$(last .pod_id)" pod1 "pod_id"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 1 "pod deleted"
  assert_eq "$(calls_count 'NOTIFY START failed: aborted')" 1 "notify"
  assert_no_file "$VOC_HOME/state/current_pod"
  assert_file_has "$UPSTREAM_CONF" "return 503"
}

t_start_skips_holiday() {
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  start
  assert_eq "$(events)" "START:skipped_holiday" "events"
  assert_eq "$(calls_count 'RP ')" 0 "no RunPod calls"
}

t_start_force_on_holiday() {
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  start --force || fail "forced start should succeed"
  assert_eq "$(last .result)" ok "result"
  assert_eq "$(last .trigger)" manual "trigger"
}

t_start_already_running() {
  start
  start
  assert_eq "$(events)" "START:ok START:already_running" "events"
  assert_eq "$(calls_count 'RP POST /pods')" 1 "only one create"
}

t_start_already_running_reenables_upstream() {
  start
  printf 'return 503;\n' > "$UPSTREAM_CONF"
  start
  assert_eq "$(last .result)" already_running "result"
  assert_file_has "$UPSTREAM_CONF" "proxy_pass https://pod1-8000.proxy.runpod.net;"
}

t_start_already_running_not_ready_restarts() {
  start
  FAKE_VLLM_BAD_HOST=pod1-8000.proxy.runpod.net start || fail "should restart"
  assert_eq "$(calls_count 'RP DELETE /pods/pod1')" 1 "old pod deleted"
  assert_eq "$(last .pod_id)" pod2 "new pod"
  assert_eq "$(last .result)" ok "result"
}

t_start_resets_recover_counters() {
  echo 3 > "$VOC_HOME/state/recover_20261116"
  touch "$VOC_HOME/state/gave_up_20261116"
  start --force
  assert_no_file "$VOC_HOME/state/recover_20261116"
  assert_no_file "$VOC_HOME/state/gave_up_20261116"
}

t_start_paused_skips_cron() {
  touch "$VOC_HOME/state/paused"
  start || fail "paused cron start should exit 0"
  assert_eq "$(events)" "START:skipped_paused" "events"
  assert_eq "$(calls_count 'RP POST')" 0 "no pod created"
}

t_start_force_ignores_paused() {
  touch "$VOC_HOME/state/paused"
  start --force || fail "force should start"
  assert_eq "$(events)" "START:ok" "events"
}

ctl() { bash "$BIN/voc-ctl.sh" "$@"; }

t_ctl_pause_stops_pod() {
  start
  ctl pause
  [ -f "$VOC_HOME/state/paused" ] || fail "paused flag"
  assert_eq "$(events)" "START:ok STOP:ok" "events"
}

t_ctl_resume_in_hours_restarts() {
  start; touch "$VOC_HOME/state/paused"
  VOC_NOW_DOW=1 VOC_NOW_HM=1000 ctl resume
  assert_no_file "$VOC_HOME/state/paused"
  assert_eq "$(events)" "START:ok STOP:ok START:ok" "events"
}

t_ctl_resume_off_hours_waits() {
  touch "$VOC_HOME/state/paused"
  VOC_NOW_DOW=1 VOC_NOW_HM=1900 ctl resume
  assert_no_file "$VOC_HOME/state/paused"
  assert_eq "$(calls_count 'RP POST')" 0 "no pod off hours"
}

export VOC_POWEROFF='echo POWEROFF >> "$T/calls"'

t_ctl_shutdown_off_hours_stops_pod_and_ec2() {
  start
  VOC_NOW_DOW=1 VOC_NOW_HM=1810 ctl shutdown
  assert_eq "$(events)" "START:ok STOP:ok" "events"
  assert_eq "$(calls_count POWEROFF)" 1 "poweroff"
}

t_ctl_shutdown_in_hours_refuses() {
  start
  VOC_NOW_DOW=1 VOC_NOW_HM=1000 ctl shutdown
  assert_eq "$(events)" "START:ok" "pod kept"
  assert_eq "$(calls_count POWEROFF)" 0 "no poweroff"
}

t_ctl_shutdown_keeps_ec2_when_pod_remains() {
  start
  FAKE_DELETE_RC=1 VOC_NOW_DOW=1 VOC_NOW_HM=1810 ctl shutdown && fail "should fail"
  assert_eq "$(calls_count POWEROFF)" 0 "no poweroff while pod billed"
  assert_eq "$(calls_count 'NOTIFY EC2 shutdown skipped')" 1 "notify"
}

t_ctl_shutdown_weekend() {
  VOC_NOW_DOW=6 VOC_NOW_HM=1000 ctl shutdown
  assert_eq "$(calls_count POWEROFF)" 1 "weekend poweroff"
}

t_ctl_boot_in_hours_starts_pod() {
  VOC_NOW_DOW=1 VOC_NOW_HM=0831 ctl boot
  assert_eq "$(events)" "START:ok" "events"
}

t_ctl_boot_paused_no_pod() {
  touch "$VOC_HOME/state/paused"
  VOC_NOW_DOW=1 VOC_NOW_HM=0831 ctl boot
  assert_eq "$(calls_count 'RP POST')" 0 "no pod while paused"
}

t_ctl_boot_off_hours_no_pod() {
  VOC_NOW_DOW=1 VOC_NOW_HM=2000 ctl boot
  assert_eq "$(calls_count 'RP POST')" 0 "no pod off hours"
}

run_tests t_ctl_shutdown_off_hours_stops_pod_and_ec2 t_ctl_shutdown_in_hours_refuses   t_ctl_shutdown_keeps_ec2_when_pod_remains t_ctl_shutdown_weekend t_ctl_boot_in_hours_starts_pod   t_ctl_boot_paused_no_pod t_ctl_boot_off_hours_no_pod t_start_paused_skips_cron t_start_force_ignores_paused t_ctl_pause_stops_pod   t_ctl_resume_in_hours_restarts t_ctl_resume_off_hours_waits t_start_ok t_start_retry_then_ok t_start_no_gpu t_start_not_ready_deletes_pod \
  t_start_not_ready_counts_slow_checks t_start_abort_deletes_pod \
  t_start_skips_holiday t_start_force_on_holiday t_start_already_running t_start_already_running_reenables_upstream t_start_already_running_not_ready_restarts t_start_resets_recover_counters
