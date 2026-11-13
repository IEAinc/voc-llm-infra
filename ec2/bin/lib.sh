#!/usr/bin/env bash
# pod-start.sh / pod-stop.sh / pod-health.sh 공통 함수. 직접 실행하지 않고 source 한다.
set -euo pipefail

VOC_HOME="${VOC_HOME:-/opt/voc-llm}"
STATE_DIR="$VOC_HOME/state"
LOG_FILE="${LOG_FILE:-/var/log/voc-llm/pod.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/voc-llm.lock}"
UPSTREAM_CONF="${UPSTREAM_CONF:-/etc/nginx/voc-llm/upstream.conf}"
RUNPOD_API="${RUNPOD_API:-https://rest.runpod.io/v1}"
READY_POLL_SEC="${READY_POLL_SEC:-15}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-1500}"
CREATE_RETRIES="${CREATE_RETRIES:-3}"
CREATE_RETRY_SEC="${CREATE_RETRY_SEC:-600}"
HEALTH_FAIL_LIMIT="${HEALTH_FAIL_LIMIT:-3}"
MAX_RECOVER="${MAX_RECOVER:-3}"

if [ -f "$VOC_HOME/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$VOC_HOME/.env"
  set +a
fi
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

now_iso()    { date +%Y-%m-%dT%H:%M:%S%:z; }
now_epoch()  { date +%s; }
today()      { echo "${VOC_TODAY:-$(date +%F)}"; }
is_holiday() { grep -qxF "$(today)" "$VOC_HOME/holidays.txt" 2>/dev/null; }
sleep_s()    { sleep "$1"; }

# log_event EVENT RESULT [--arg k v | --argjson k v ...]
log_event() {
  local event=$1 result=$2
  shift 2
  jq -cn --arg event "$event" --arg ts "$(now_iso)" --arg result "$result" "$@" '$ARGS.named' >> "$LOG_FILE"
}

# notify SUBJECT(ASCII) MESSAGE. 알림 실패가 운영 흐름을 막지 않도록 항상 성공한다.
notify() {
  [ -n "${SNS_TOPIC_ARN:-}" ] || return 0
  aws sns publish --region "${SNS_REGION:-ap-northeast-2}" --topic-arn "$SNS_TOPIC_ARN" \
    --subject "[voc-llm] $1" --message "$2" >/dev/null 2>&1 || true
}

nginx_reload() {
  if [ -n "${VOC_NO_RELOAD:-}" ]; then return 0; fi
  nginx -t -q && nginx -s reload
}

write_upstream() {
  printf '%s\n' "$1" > "$UPSTREAM_CONF.tmp"
  mv "$UPSTREAM_CONF.tmp" "$UPSTREAM_CONF"
  nginx_reload
}
upstream_on() {
  write_upstream "proxy_pass https://$1;
proxy_set_header Host $1;"
}
upstream_off() {
  write_upstream "return 503 '{\"error\":{\"message\":\"LLM service is available weekdays 09:00-18:00 KST\",\"type\":\"service_unavailable\"}}';"
}

# rp METHOD PATH [JSON] : 본문 stdout, 반환 0=2xx 4=404 1=그 외/네트워크 오류
rp() {
  local args=(-sS -m 30 -w '\n%{http_code}' -X "$1" "$RUNPOD_API$2" -H "Authorization: Bearer $RUNPOD_API_KEY")
  if [ $# -ge 3 ]; then args+=(-H 'Content-Type: application/json' -d "$3"); fi
  local out code
  out=$(curl "${args[@]}") || return 1
  code=${out##*$'\n'}
  printf '%s' "${out%$'\n'*}"
  case $code in
    2??) return 0 ;;
    404) return 4 ;;
    *) return 1 ;;
  esac
}

# vllm_status HOST : /v1/models HTTP 코드 출력 (연결 실패 000)
vllm_status() {
  curl -s -o /dev/null -m 20 -w '%{http_code}' -H "Authorization: Bearer $VLLM_API_KEY" "https://$1/v1/models" || true
}

pod_id_of() { jq -er '.id // empty' <<<"$1" 2>/dev/null; }

# pod_spec STAGE : 1 = Network Volume 사용, 2 = 볼륨 없음(HF 에서 다운로드)
pod_spec() {
  jq -n --arg stage "$1" --rawfile gpus "$VOC_HOME/gpu-priority.txt" \
    --arg image "$VLLM_IMAGE" --arg model "$MODEL_ID" --arg vol "${NETWORK_VOLUME_ID:-}" \
    --arg hf "$HF_TOKEN" --arg key "$VLLM_API_KEY" --arg maxlen "${MAX_MODEL_LEN:-32768}" \
    --arg extra "${VLLM_EXTRA_ARGS:-}" '
    {
      name: "voc-llm",
      cloudType: "SECURE",
      gpuCount: 1,
      gpuTypeIds: ($gpus | split("\n") | map(select(length > 0 and (startswith("#") | not)))),
      gpuTypePriority: "custom",
      imageName: $image,
      containerDiskInGb: 40,
      ports: ["8000/http"],
      env: {
        HF_TOKEN: $hf,
        VLLM_API_KEY: $key,
        HF_HOME: (if $stage == "1" then "/workspace/hf" else "/root/.cache/huggingface" end)
      },
      dockerStartCmd: (["--model", $model, "--served-model-name", "voc-llm",
                        "--host", "0.0.0.0", "--port", "8000",
                        "--max-model-len", $maxlen, "--gpu-memory-utilization", "0.90",
                        "--kv-cache-dtype", "auto"]
                       + ($extra | split(" ") | map(select(length > 0))))
    }
    + (if $stage == "1" then {networkVolumeId: $vol, volumeMountPath: "/workspace"} else {} end)'
}

# --- 이 아래에 Task 2~4 함수를 추가한다. 스텁 로딩 줄은 항상 파일 마지막에 둔다. ---

# create_pod : 1단계(볼륨 DC) CREATE_RETRIES 회 → 실패 시 2단계(볼륨 없음) 1회
create_pod() {
  local i out
  CREATE_FAILS=0
  if [ -n "${NETWORK_VOLUME_ID:-}" ]; then
    for ((i = 0; i < CREATE_RETRIES; i++)); do
      if [ "$i" -gt 0 ]; then sleep_s "$CREATE_RETRY_SEC"; fi
      if out=$(rp POST /pods "$(pod_spec 1)") && pod_id_of "$out" >/dev/null; then
        CREATE_STAGE=1
        printf '%s' "$out" > "$STATE_DIR/created.json"
        return 0
      fi
      CREATE_FAILS=$((CREATE_FAILS + 1))
    done
  fi
  if out=$(rp POST /pods "$(pod_spec 2)") && pod_id_of "$out" >/dev/null; then
    CREATE_STAGE=2
    printf '%s' "$out" > "$STATE_DIR/created.json"
    return 0
  fi
  CREATE_FAILS=$((CREATE_FAILS + 1))
  return 1
}

# _start_abort POD_ID : do_start 가 Pod 생성 후 예기치 않게 중단될 때 EXIT trap 에서 호출
_start_abort() {
  trap - EXIT INT TERM
  local dmsg
  if rp DELETE "/pods/$1" >/dev/null 2>&1; then dmsg="삭제했습니다"; else dmsg="삭제 실패 — RunPod 콘솔에서 직접 삭제 필요"; fi
  upstream_off || true
  log_event START failed_aborted --arg pod_id "$1" || true
  notify "START failed: aborted" "START 중단: Pod $1 $dmsg." || true
}

# do_start TRIGGER(cron|manual|health)
do_start() {
  local trigger=$1 requested_at t0 created_at created_epoch pod info id gpu dc cost host waited code ready_start dmsg
  requested_at=$(now_iso)
  t0=$(now_epoch)
  if [ "$trigger" != health ]; then rm -f "$STATE_DIR"/recover_* "$STATE_DIR"/gave_up_*; fi

  if ! create_pod; then
    upstream_off || true
    log_event START failed_no_gpu --arg trigger "$trigger" --arg requested_at "$requested_at" --argjson retries "$CREATE_FAILS"
    notify "START failed: no GPU" "Secure 48GB GPU를 확보하지 못했습니다(1·2단계 모두 실패, 시도 ${CREATE_FAILS}회)."
    return 1
  fi
  created_at=$(now_iso)
  created_epoch=$(now_epoch)
  pod=$(cat "$STATE_DIR/created.json")
  id=$(pod_id_of "$pod")
  # 이후 어떤 이유로든 중단되면 기록되지 않은 Pod 가 남지 않도록 삭제한다(과금 방지)
  trap "_start_abort '$id'" EXIT
  trap 'exit 143' INT TERM

  # 생성 응답에 GPU/DC 정보가 없을 수 있어 GET 결과와 합친다
  info=$(rp GET "/pods/$id" 2>/dev/null) || info='{}'
  info=$(jq -cs '.[0] * .[1]' <<<"$pod$info" 2>/dev/null) || info=$pod
  gpu=$(jq -r '.machine.gpuTypeId // .machine.gpuDisplayName // .gpuTypeId // "unknown"' <<<"$info")
  dc=$(jq -r '.machine.dataCenterId // .dataCenterId // "unknown"' <<<"$info")
  cost=$(jq -r '(.costPerHr // .adjustedCostPerHr // 0) | tonumber? // 0' <<<"$info")
  host="$id-8000.proxy.runpod.net"

  ready_start=$(now_epoch)
  while :; do
    code=$(vllm_status "$host")
    if [ "$code" = 200 ]; then break; fi
    waited=$(($(now_epoch) - ready_start))
    if [ "$waited" -ge "$READY_TIMEOUT_SEC" ]; then
      trap - EXIT INT TERM
      if rp DELETE "/pods/$id" >/dev/null 2>&1; then dmsg="삭제했습니다"; else dmsg="삭제 실패 — RunPod 콘솔에서 직접 삭제 필요"; fi
      upstream_off || true
      log_event START failed_not_ready --arg trigger "$trigger" --arg requested_at "$requested_at"         --arg pod_id "$id" --arg gpu "$gpu" --argjson waited_sec "$waited" --arg last_http "$code"
      notify "START failed: vLLM not ready" "Pod $id ($gpu)가 ${READY_TIMEOUT_SEC}초 안에 준비되지 않았습니다(마지막 응답: $code). Pod $dmsg."
      return 1
    fi
    sleep_s "$READY_POLL_SEC"
  done

  if ! upstream_on "$host"; then
    trap - EXIT INT TERM
    if rp DELETE "/pods/$id" >/dev/null 2>&1; then dmsg="삭제했습니다"; else dmsg="삭제 실패 — RunPod 콘솔에서 직접 삭제 필요"; fi
    upstream_off || true
    log_event START failed_reload --arg trigger "$trigger" --arg requested_at "$requested_at" --arg pod_id "$id" --arg gpu "$gpu"
    notify "START failed: nginx reload" "nginx reload 실패. Pod $id $dmsg. 'nginx -t' 결과를 확인하세요."
    return 1
  fi

  jq -n --arg pod_id "$id" --arg gpu "$gpu" --arg datacenter "$dc" --argjson cost_per_hr "$cost" \
    --arg started_at "$created_at" --argjson created_epoch "$created_epoch" --arg endpoint "https://$host" \
    '$ARGS.named' > "$STATE_DIR/current_pod"
  echo 0 > "$STATE_DIR/health_fail"
  trap - EXIT INT TERM
  log_event START ok --arg trigger "$trigger" --arg requested_at "$requested_at" --arg ready_at "$(now_iso)" \
    --argjson ready_sec "$(($(now_epoch) - t0))" --arg pod_id "$id" --arg gpu "$gpu" --arg datacenter "$dc" \
    --argjson stage "$CREATE_STAGE" --argjson retries "$CREATE_FAILS" --argjson cost_per_hr "$cost" \
    --arg model "$MODEL_ID" --arg endpoint "https://$host"
}

# do_stop LABEL(ok|replaced) : 먼저 upstream 차단 → 삭제 3회 시도 → STOP 로그
do_stop() {
  local label=${1:-ok} cur id gpu cost created i rc=1 sec uptime est
  upstream_off || true
  if [ ! -f "$STATE_DIR/current_pod" ]; then
    log_event STOP no_pod
    return 0
  fi
  cur=$(cat "$STATE_DIR/current_pod")
  id=$(jq -r .pod_id <<<"$cur")
  gpu=$(jq -r .gpu <<<"$cur")
  cost=$(jq -r .cost_per_hr <<<"$cur")
  created=$(jq -r .created_epoch <<<"$cur")

  for i in 1 2 3; do
    rc=0
    rp DELETE "/pods/$id" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; then break; fi
    if [ "$i" -lt 3 ]; then sleep_s 30; fi
  done
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
    log_event STOP failed_delete --arg pod_id "$id" --arg gpu "$gpu"
    notify "STOP failed: pod not deleted" "Pod $id 삭제에 3회 실패했습니다. 과금이 계속되므로 RunPod 콘솔에서 직접 삭제한 뒤 /opt/voc-llm/state/current_pod 를 지우세요."
    return 1
  fi

  sec=$(($(now_epoch) - created))
  read -r uptime est < <(awk -v s="$sec" -v c="$cost" 'BEGIN { printf "%.2f %.2f\n", s / 3600, s / 3600 * c }')
  log_event STOP "$label" --arg pod_id "$id" --arg gpu "$gpu" --arg started_at "$(jq -r .started_at <<<"$cur")" \
    --argjson uptime_hr "$uptime" --argjson cost_per_hr "$cost" --argjson est_cost_usd "$est"
  rm -f "$STATE_DIR/current_pod"
}

if [ -n "${VOC_STUB:-}" ]; then
  # shellcheck disable=SC1090
  . "$VOC_STUB"
fi
