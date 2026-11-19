#!/usr/bin/env bash
# pod-start.sh / pod-stop.sh / pod-health.sh 공통 함수. 직접 실행하지 않고 source 한다.
set -euo pipefail

VOC_HOME="${VOC_HOME:-/opt/voc-llm}"
STATE_DIR="$VOC_HOME/state"
LOG_FILE="${LOG_FILE:-/var/log/voc-llm/pod.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/voc-llm.lock}"
UPSTREAM_CONF="${UPSTREAM_CONF:-/etc/nginx/voc-llm/upstream.conf}"
RUNPOD_API="${RUNPOD_API:-https://api.runpod.io/v2}"   # REST v1(rest.runpod.io)은 2026-11-15 종료
READY_POLL_SEC="${READY_POLL_SEC:-15}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-900}"
CREATE_RETRIES="${CREATE_RETRIES:-3}"
CREATE_RETRY_SEC="${CREATE_RETRY_SEC:-600}"
HEALTH_FAIL_LIMIT="${HEALTH_FAIL_LIMIT:-3}"
MAX_RECOVER="${MAX_RECOVER:-3}"
HOLIDAY_API_URL="${HOLIDAY_API_URL:-https://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/getRestDeInfo}"
HOLIDAY_RETRIES="${HOLIDAY_RETRIES:-3}"
HOLIDAY_RETRY_SEC="${HOLIDAY_RETRY_SEC:-600}"

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
# 수동 휴무일은 항상 적용. API 공휴일은 마지막 갱신이 성공했을 때만 적용 (실패한 주는 평일 모두 운영)
is_holiday() {
  if grep -qxF "$(today)" "$VOC_HOME/holidays.txt" 2>/dev/null; then return 0; fi
  if [ -f "$STATE_DIR/holiday_sync_failed" ]; then return 1; fi
  grep -qxF "$(today)" "$VOC_HOME/holidays-api.txt" 2>/dev/null
}
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

# daily_pod_lines DAY : 그날 Pod 켜짐/꺼짐 기록 (daily-report.sh)
daily_pod_lines() {
  jq -r --arg d "$1" '
    select(.ts[0:10] == $d and (.event == "START" or .event == "STOP") and .result != "no_pod")
    | .ts[11:16] + " "
      + (if .event == "START" and .result == "ok" then "켜짐 (준비 \(.ready_sec)초, \(.gpu), \(.datacenter))"
         elif .event == "STOP" and (.result == "ok" or .result == "replaced") then "꺼짐 (가동 \(.uptime_hr)시간, 약 $\(.est_cost_usd))"
         else "\(.event) \(.result)" end)' "$LOG_FILE" 2>/dev/null | grep . || echo "기록 없음"
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

# rp METHOD PATH [JSON] : 본문 stdout, 반환 0=2xx 4=404 3=400/403(이 GPU 배치 불가) 1=그 외/네트워크 오류
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
    400|403) return 3 ;;
    *) return 1 ;;
  esac
}

# vllm_status HOST : /v1/models HTTP 코드 출력 (연결 실패 000)
vllm_status() {
  curl -s -o /dev/null -m 20 -w '%{http_code}' -H "Authorization: Bearer $VLLM_API_KEY" "https://$1/v1/models" || true
}

pod_id_of() { jq -er '.id // empty' <<<"$1" 2>/dev/null; }

# gpu_list : gpu-priority.txt 의 GPU ID, 우선순위 순. '#' 줄과 빈 줄 제외
gpu_list() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$VOC_HOME/gpu-priority.txt"; }

# pod_spec GPU_ID : REST v2 형식. v2 는 GPU 1종만 받으므로 우선순위 순회는 create_pod 가 한다.
# 볼륨 없음. 기동 시 HF 에서 모델을 컨테이너 디스크로 다운로드
pod_spec() {
  jq -n --arg gpu "$1" \
    --arg image "$VLLM_IMAGE" --arg model "$MODEL_ID" \
    --arg hf "$HF_TOKEN" --arg key "$VLLM_API_KEY" --arg maxlen "${MAX_MODEL_LEN:-32768}" \
    --arg extra "${VLLM_EXTRA_ARGS:-}" '
    {
      name: "voc-llm",
      cloud: "SECURE",
      gpu: {id: $gpu, count: 1},
      image: $image,
      disk: 40,
      ports: ["8000/http"],
      env: {
        HF_TOKEN: $hf,
        VLLM_API_KEY: $key,
        HF_HOME: "/root/.cache/huggingface"
      },
      cmd: (["--model", $model, "--served-model-name", "voc-llm",
             "--host", "0.0.0.0", "--port", "8000",
             "--max-model-len", $maxlen, "--gpu-memory-utilization", "0.90",
             "--kv-cache-dtype", "auto"]
            + ($extra | split(" ") | map(select(length > 0))))
    }'
}

# --- 이 아래에 Task 2~4 함수를 추가한다. 스텁 로딩 줄은 항상 파일 마지막에 둔다. ---

# create_pod : gpu-priority.txt 순서로 GPU 를 하나씩 시도하는 회차를 CREATE_RETRIES 회, 사이에 CREATE_RETRY_SEC 대기.
# 400/403 은 그 GPU 를 배치하지 못한 것으로 보고 다음 GPU 로 넘어간다. 그 외 오류(네트워크, 401, 402, 422, 5xx)는
# 그 회차를 끝낸다. CREATE_ERR 에 마지막 응답, CREATE_NO_GPU=1 이면 마지막 회차가 모두 400/403 이었다.
create_pod() {
  local i g out rc
  CREATE_FAILS=0 CREATE_ERR="" CREATE_NO_GPU=1
  for ((i = 0; i < CREATE_RETRIES; i++)); do
    if [ "$i" -gt 0 ]; then sleep_s "$CREATE_RETRY_SEC"; fi
    CREATE_NO_GPU=1
    while read -r g; do
      rc=0
      out=$(rp POST /pods "$(pod_spec "$g")" 2>&1) || rc=$?
      if [ "$rc" -eq 0 ] && pod_id_of "$out" >/dev/null; then
        printf '%s' "$out" > "$STATE_DIR/created.json"
        return 0
      fi
      CREATE_ERR="$g: $(jq -r '.detail // empty' <<<"$out" 2>/dev/null || true)"
      if [ "$CREATE_ERR" = "$g: " ]; then CREATE_ERR="$g: $(head -c 200 <<<"$out")"; fi
      if [ "$rc" -ne 3 ]; then CREATE_NO_GPU=0; break; fi
    done < <(gpu_list)
    CREATE_FAILS=$((CREATE_FAILS + 1))
  done
  return 1
}

# _start_abort POD_ID : do_start 가 Pod 생성 후 예기치 않게 중단될 때 EXIT trap 에서 호출
_start_abort() {
  trap - EXIT INT TERM
  local dmsg
  if rp DELETE "/pods/$1" >/dev/null 2>&1; then dmsg="삭제했습니다"; else dmsg="삭제 실패 — RunPod 콘솔에서 직접 삭제 필요"; fi
  rm -f "$STATE_DIR/current_pod" "$STATE_DIR/current_pod.tmp"
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
    if [ "$CREATE_NO_GPU" = 1 ]; then
      log_event START failed_no_gpu --arg trigger "$trigger" --arg requested_at "$requested_at" --argjson retries "$CREATE_FAILS" --arg error "$CREATE_ERR"
      notify "START failed: no GPU" "Secure 48GB GPU를 확보하지 못했습니다(시도 ${CREATE_FAILS}회 모두 실패). 마지막 응답: $CREATE_ERR"
    else
      log_event START failed_api --arg trigger "$trigger" --arg requested_at "$requested_at" --argjson retries "$CREATE_FAILS" --arg error "$CREATE_ERR"
      notify "START failed: RunPod API error" "RunPod API 호출이 실패해 Pod를 만들지 못했습니다(${CREATE_FAILS}회). 키, 잔액, API 주소를 확인하세요. 마지막 응답: $CREATE_ERR"
    fi
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
  gpu=$(jq -r '.gpu.id // "unknown"' <<<"$info")
  dc=$(jq -r '.dataCenterId // "unknown"' <<<"$info")
  cost=$(jq -r '(.cost // 0) | tonumber? // 0' <<<"$info")
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
      log_event START failed_not_ready --arg trigger "$trigger" --arg requested_at "$requested_at" \
        --arg pod_id "$id" --arg gpu "$gpu" --argjson waited_sec "$waited" --arg last_http "$code"
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
    '$ARGS.named' > "$STATE_DIR/current_pod.tmp" && mv "$STATE_DIR/current_pod.tmp" "$STATE_DIR/current_pod" || return 1
  echo 0 > "$STATE_DIR/health_fail"
  trap - EXIT INT TERM
  log_event START ok --arg trigger "$trigger" --arg requested_at "$requested_at" --arg ready_at "$(now_iso)" \
    --argjson ready_sec "$(($(now_epoch) - t0))" --arg pod_id "$id" --arg gpu "$gpu" --arg datacenter "$dc" \
    --argjson retries "$CREATE_FAILS" --argjson cost_per_hr "$cost" \
    --arg model "$MODEL_ID" --arg endpoint "https://$host"
}

# stop_orphan CUR_ID : created.json 의 Pod 가 현재 Pod 와 다르면(기록되지 못한 Pod) 삭제한다. 404 는 정상
stop_orphan() {
  local oid rc=0 cf="$STATE_DIR/created.json"
  [ -f "$cf" ] || return 0
  oid=$(pod_id_of "$(cat "$cf")") || oid=""
  if [ -n "$oid" ] && [ "$oid" != "${1:-}" ]; then
    rp DELETE "/pods/$oid" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then return 0; fi
    rm -f "$cf"
  fi
}

# do_stop LABEL(ok|replaced) : 먼저 upstream 차단 → 삭제 3회 시도 → STOP 로그
do_stop() {
  local label=${1:-ok} cur id gpu cost created i rc=1 sec uptime est
  upstream_off || true
  stop_orphan "$(jq -r '.pod_id // empty' "$STATE_DIR/current_pod" 2>/dev/null || true)"
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

recover_count() { cat "$STATE_DIR/recover_$(today | tr -d -)" 2>/dev/null || echo 0; }

# health_recover : 당일 MAX_RECOVER 회까지 장애 Pod 삭제 → 새 Pod 생성
health_recover() {
  local day n
  day=$(today | tr -d -)
  n=$(recover_count)
  if [ "$n" -ge "$MAX_RECOVER" ]; then
    touch "$STATE_DIR/gave_up_$day"
    log_event HEALTH gave_up --argjson recover_count_today "$n"
    notify "RunPod recovery gave up" "오늘 자동 복구를 ${n}회 시도했지만 실패했습니다. 원인을 확인한 뒤 'pod-start.sh --force'를 실행하세요."
    return 0
  fi
  echo $((n + 1)) > "$STATE_DIR/recover_$day"
  echo 0 > "$STATE_DIR/health_fail"
  if [ -f "$STATE_DIR/current_pod" ]; then
    # 삭제 실패 시 새 Pod를 만들면 이중 과금 → 중단 (do_stop 이 이미 알림)
    do_stop replaced || return 0
  else
    upstream_off || true
  fi
  if do_start health; then
    notify "RunPod recovered" "자동 복구 완료: $(jq -r '.pod_id + " (" + .gpu + ")"' "$STATE_DIR/current_pod")"
  else
    notify "RunPod recovery failed" "자동 복구 $((n + 1))회차 실패. 2분 뒤 다음 점검에서 다시 시도합니다."
  fi
}

do_health() {
  local day fail cur id gpu rc st status="" code check detail
  day=$(today | tr -d -)
  if [ -f "$STATE_DIR/maintenance" ] || [ -f "$STATE_DIR/paused" ] || [ -f "$STATE_DIR/gave_up_$day" ]; then return 0; fi

  if [ ! -f "$STATE_DIR/current_pod" ]; then
    log_event HEALTH no_pod --argjson recover_count_today "$(recover_count)"
    health_recover
    return 0
  fi
  fail=$(cat "$STATE_DIR/health_fail" 2>/dev/null || echo 0)
  cur=$(cat "$STATE_DIR/current_pod")
  id=$(jq -r .pod_id <<<"$cur")
  gpu=$(jq -r .gpu <<<"$cur")

  # 점검 A: RunPod 플랫폼 상태 (API 장애 시 판정 보류)
  rc=0
  st=$(rp GET "/pods/$id" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 4 ]; then
    status=NOT_FOUND
  elif [ "$rc" -eq 0 ]; then
    status=$(jq -r '.status // "RUNNING"' <<<"$st" 2>/dev/null || echo RUNNING)
  fi

  # PROVISIONING/STARTING 은 일시 상태라 점검 B(vLLM 응답)로 판정한다
  case "$status" in RUNNING|PROVISIONING|STARTING) status="" ;; esac
  if [ -n "$status" ]; then
    check=A
    detail="pod status $status"
    fail=$HEALTH_FAIL_LIMIT
  else
    # 점검 B: vLLM 응답
    code=$(vllm_status "$id-8000.proxy.runpod.net")
    if [ "$code" = 200 ]; then
      if [ "$fail" -gt 0 ]; then log_event HEALTH recovered_self --arg pod_id "$id" --argjson fail_count "$fail"; fi
      echo 0 > "$STATE_DIR/health_fail"
      return 0
    fi
    fail=$((fail + 1))
    echo "$fail" > "$STATE_DIR/health_fail"
    check=B
    detail="http $code"
    if [ "$fail" -eq 1 ]; then
      log_event HEALTH degraded --arg pod_id "$id" --arg gpu "$gpu" --arg check B --arg detail "$detail" --argjson fail_count 1
    fi
    if [ "$fail" -lt "$HEALTH_FAIL_LIMIT" ]; then return 0; fi
  fi

  log_event HEALTH down --arg pod_id "$id" --arg gpu "$gpu" --arg check "$check" --arg detail "$detail" \
    --argjson fail_count "$fail" --argjson recover_count_today "$(recover_count)"
  notify "RunPod DOWN" "RunPod 장애 감지: pod $id ($gpu), 점검 $check, $detail. 자동 복구를 시작합니다."
  health_recover
}

# holiday_api YEAR : 공공데이터포털 특일정보(공휴일) 원본 응답
holiday_api() {
  curl -sS -f -m 20 -G "$HOLIDAY_API_URL" --data-urlencode "serviceKey=${HOLIDAY_API_KEY:-}" \
    -d "solYear=$1" -d numOfRows=100 -d _type=json
}

# holiday_dates JSON : resultCode 00 이고 isHoliday=Y 인 날짜를 YYYY-MM-DD 로 출력. 0건/비정상이면 실패
holiday_dates() {
  jq -er 'select(.response.header.resultCode == "00")
    | ((.response.body.items | if type == "object" then .item else null end) // [])
    | (if type == "array" then . elif type == "object" then [.] else [] end)
    | map(select(.isHoliday == "Y") | (.locdate | tostring) | "\(.[0:4])-\(.[4:6])-\(.[6:8])")
    | .[]' <<<"$1" 2>/dev/null
}

do_holiday_sync() {
  local year next i raw cur="" nxt="" nn=0
  year=$(today | cut -c1-4)
  next=$((year + 1))
  for ((i = 0; i < HOLIDAY_RETRIES; i++)); do
    if [ "$i" -gt 0 ]; then sleep_s "$HOLIDAY_RETRY_SEC"; fi
    # -ge 10: 정상 여부 최소 점검선 (한국 공휴일은 연 15일 이상)
    if raw=$(holiday_api "$year") && cur=$(holiday_dates "$raw") && [ "$(wc -l <<<"$cur")" -ge 10 ]; then break; fi
    cur=""
  done
  if [ -z "$cur" ]; then
    touch "$STATE_DIR/holiday_sync_failed"
    log_event HOLIDAY_SYNC failed --argjson year "$year" --argjson attempts "$HOLIDAY_RETRIES"
    notify "Holiday sync failed" "공휴일 API 갱신에 ${HOLIDAY_RETRIES}회 실패했습니다. 다음 갱신이 성공할 때까지 공휴일 판정을 끄고 평일에는 모두 운영합니다(holidays.txt 수동 휴무일은 계속 적용). HOLIDAY_API_KEY 확인 후 holiday-sync.sh 를 수동 실행하세요."
    return 1
  fi
  if raw=$(holiday_api "$next") && jq -e '.response.header.resultCode == "00"' <<<"$raw" >/dev/null 2>&1; then
    nxt=$(holiday_dates "$raw") || nxt=""   # 정상 응답 0건 = 미공개, 이월하지 않음
  else
    # 내년 조회 실패: 이전에 받아 둔 내년 날짜를 유지
    nxt=$(grep "^$next" "$VOC_HOME/holidays-api.txt" 2>/dev/null || true)
  fi
  if [ -n "$nxt" ]; then nn=$(wc -l <<<"$nxt"); fi
  { printf '%s\n' "$cur"; if [ -n "$nxt" ]; then printf '%s\n' "$nxt"; fi; } | sort -u > "$VOC_HOME/holidays-api.txt.tmp"
  mv "$VOC_HOME/holidays-api.txt.tmp" "$VOC_HOME/holidays-api.txt"
  rm -f "$STATE_DIR/holiday_sync_failed"
  log_event HOLIDAY_SYNC ok --argjson year "$year" --argjson count "$(wc -l < "$VOC_HOME/holidays-api.txt")" --argjson next_year_count "$nn"
}

if [ -n "${VOC_STUB:-}" ]; then
  # shellcheck disable=SC1090
  . "$VOC_STUB"
fi
