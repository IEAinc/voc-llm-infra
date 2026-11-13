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

if [ -n "${VOC_STUB:-}" ]; then
  # shellcheck disable=SC1090
  . "$VOC_STUB"
fi
