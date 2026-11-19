#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
lib() { ( . "$BIN/lib.sh"; "$@" ); }

t_pod_spec() {
  local j; j=$(lib pod_spec "NVIDIA A40")
  assert_eq "$(jq -r .cloud <<<"$j")" SECURE "cloud"
  assert_eq "$(jq -r 'has("networkVolumeId")' <<<"$j")" false "no volume"
  assert_eq "$(jq -r 'has("volumeMountPath")' <<<"$j")" false "no mount"
  assert_eq "$(jq -r .env.HF_HOME <<<"$j")" /root/.cache/huggingface "HF_HOME"
  assert_eq "$(jq -r .env.VLLM_API_KEY <<<"$j")" test-vllm "VLLM_API_KEY"
  assert_eq "$(jq -c .gpu <<<"$j")" '{"id":"NVIDIA A40","count":1}' "gpu"
  assert_eq "$(jq -r .image <<<"$j")" "vllm/vllm-openai:v9.9.9" "image"
  assert_eq "$(jq -r .disk <<<"$j")" 40 "disk"
  assert_eq "$(jq -r '.ports|join(",")' <<<"$j")" "8000/http" "ports"
  assert_eq "$(jq -r '.cmd|join(" ")' <<<"$j")" \
    "--model org/test-model --served-model-name voc-llm --host 0.0.0.0 --port 8000 --max-model-len 32768 --gpu-memory-utilization 0.90 --kv-cache-dtype auto" "cmd"
  assert_eq "$(jq -r 'keys|join(",")' <<<"$j")" "cloud,cmd,disk,env,gpu,image,name,ports" "v2 fields only"
}

t_gpu_list() {
  assert_eq "$(lib gpu_list | paste -sd,)" "NVIDIA RTX A6000,NVIDIA A40,NVIDIA L40" "gpu order, comments/blank ignored"
}

t_pod_spec_extra_args() {
  local j; j=$(VLLM_EXTRA_ARGS='--limit-mm-per-prompt {"image":0}' lib pod_spec "NVIDIA A40")
  assert_eq "$(jq -r '.cmd[-2:]|join(" ")' <<<"$j")" '--limit-mm-per-prompt {"image":0}' "extra args appended"
}

t_upstream_on_off() {
  lib upstream_on abc-8000.proxy.runpod.net
  assert_file_has "$UPSTREAM_CONF" "proxy_pass https://abc-8000.proxy.runpod.net;"
  assert_file_has "$UPSTREAM_CONF" "proxy_set_header Host abc-8000.proxy.runpod.net;"
  lib upstream_off
  assert_file_has "$UPSTREAM_CONF" "return 503"
  grep -q proxy_pass "$UPSTREAM_CONF" && fail "proxy_pass must be gone after upstream_off"
  true
}

t_daily_pod_lines() {
  cat > "$LOG_FILE" <<'EOF'
{"event":"START","ts":"2026-11-18T08:34:18+09:00","result":"ok","ready_sec":219,"gpu":"NVIDIA A40","datacenter":"CA-MTL-1"}
{"event":"STOP","ts":"2026-11-18T18:00:02+09:00","result":"ok","uptime_hr":9.49,"est_cost_usd":5.6}
{"event":"START","ts":"2026-11-19T08:30:01+09:00","result":"ok","ready_sec":200,"gpu":"NVIDIA A40","datacenter":"X"}
{"event":"STOP","ts":"2026-11-18T19:30:00+09:00","result":"no_pod"}
EOF
  assert_eq "$(lib daily_pod_lines 2026-11-18)" "08:34 켜짐 (준비 219초, NVIDIA A40, CA-MTL-1)
18:00 꺼짐 (가동 9.49시간, 약 \$5.6)" "only that day, no_pod skipped"
  assert_eq "$(lib daily_pod_lines 2026-11-20)" "기록 없음" "empty day"
}

t_log_event() {
  lib log_event START ok --arg pod_id p1 --argjson retries 2
  assert_eq "$(last .event)" START "event"
  assert_eq "$(last .result)" ok "result"
  assert_eq "$(last .pod_id)" p1 "pod_id"
  assert_eq "$(last .retries)" 2 "retries is number"
  last .ts | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$' || fail "ts format"
}

t_holiday() {
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  lib is_holiday || fail "2026-11-16 should be holiday"
  VOC_TODAY=2026-11-17 lib is_holiday && fail "2026-11-17 should not be holiday"
  true
}

t_repo_gpu_priority_first_is_a40() {
  assert_eq "$(grep -v '^#' "$ROOT/ec2/gpu-priority.txt" | grep -v '^$' | head -1)" "NVIDIA A40" "repo gpu-priority first line"
}

run_tests t_daily_pod_lines t_pod_spec t_gpu_list t_pod_spec_extra_args t_upstream_on_off t_log_event t_holiday t_repo_gpu_priority_first_is_a40
