# lib.sh 마지막에 source 되어 네트워크 함수를 대체한다. 모든 호출은 $T/calls 에 기록된다.
# 동작 제어 환경변수:
#   FAKE_CREATE_FAILS=N   처음 N번의 POST /pods 가 400(재고 없음). 회차마다 GPU 수만큼 POST 한다
#   FAKE_CREATE_RC=N      POST /pods 가 항상 이 값으로 실패 (1=API 오류)
#   FAKE_POD_STATUS       GET /pods/{id}: RUNNING(기본) | EXITED 등 | GONE(404) | APIDOWN(오류)
#   FAKE_DELETE_RC        DELETE 반환값 (기본 0)
#   FAKE_VLLM_CODE        vllm_status 기본 응답 (기본 200)
#   FAKE_VLLM_BAD_HOST    이 host 에 대해서만 000 응답
#   FAKE_CLOCK            설정 시 now_epoch 가 가짜 시계(sleep_s/vllm_status 가 진행시킴)
#   FAKE_VLLM_DELAY       vllm_status 1회당 소요 초 (기본 0)
#   FAKE_ABORT_AFTER_CREATE  vllm_status 가 부모 셸에 SIGTERM 을 보낸다
_tick() { echo $(($(cat "$T/clock" 2>/dev/null || echo 0) + $1)) > "$T/clock"; }
if [ -n "${FAKE_CLOCK:-}" ]; then now_epoch() { echo $((1800000000 + $(cat "$T/clock" 2>/dev/null || echo 0))); }; fi
sleep_s() { echo "SLEEP $1" >> "$T/calls"; _tick "$1"; }
notify()  { echo "NOTIFY $1" >> "$T/calls"; }
uptime_report() { echo "REPORT $1" >> "$T/calls"; }

rp() {
  echo "RP $1 $2" >> "$T/calls"
  case "$1 $2" in
    "POST /pods")
      local n
      n=$(cat "$T/create_n" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$T/create_n"
      if [ -n "${FAKE_CREATE_RC:-}" ]; then echo '{"title":"Payment Required","status":402,"detail":"insufficient balance"}'; return "$FAKE_CREATE_RC"; fi
      if [ "$n" -lt "${FAKE_CREATE_FAILS:-0}" ]; then echo '{"title":"Bad Request","status":400,"detail":"no instances available"}'; return 3; fi
      jq -nc --arg id "pod$((n + 1))" --arg g "$(jq -r .gpu.id <<<"$3")" '{id: $id, cost: 0.59, gpu: {id: $g, count: 1}, dataCenterId: "EU-RO-1", status: "PROVISIONING"}'
      ;;
    "GET /pods/"*)
      case "${FAKE_POD_STATUS:-RUNNING}" in
        GONE) return 4 ;;
        APIDOWN) return 1 ;;
        *) echo "{\"status\":\"${FAKE_POD_STATUS:-RUNNING}\"}" ;;
      esac
      ;;
    "DELETE /pods/"*) return "${FAKE_DELETE_RC:-0}" ;;
  esac
}

vllm_status() {
  echo "VLLM $1" >> "$T/calls"
  _tick "${FAKE_VLLM_DELAY:-0}"
  if [ -n "${FAKE_ABORT_AFTER_CREATE:-}" ]; then kill -TERM $$; sleep 0.3; fi
  if [ -n "${FAKE_VLLM_BAD_HOST:-}" ] && [ "$1" = "$FAKE_VLLM_BAD_HOST" ]; then echo 000; return; fi
  echo "${FAKE_VLLM_CODE:-200}"
}

# FAKE_HOLIDAY_MODE: ok(기본) | fail | badcode | xml | few
# FAKE_HOLIDAY_FAILS=N : 처음 N번 호출 실패
# FAKE_HOLIDAY_FAIL_YEAR=YYYY : 이 연도 호출은 항상 실패
# FAKE_HOLIDAY_MAX_YEAR=YYYY : 이 연도보다 큰 해는 0건 응답 (내년 자료 미공개 상황)
fake_holidays() {  # fake_holidays YEAR COUNT : isHoliday=Y COUNT 개 + isHoliday=N 1개
  jq -nc --arg y "$1" --argjson c "$2" '
    ["0101","0301","0505","0606","0815","1003","1009","1225","0128","0129","0130","0524","0603","0917","0918","0919"] as $d
    | {response: {header: {resultCode: "00", resultMsg: "NORMAL SERVICE."},
                  body: {items: {item: (
                    [range(0; $c) | {dateName: "휴일", isHoliday: "Y", locdate: (($y + $d[.]) | tonumber)}]
                    + [{dateName: "기념일", isHoliday: "N", locdate: (($y + "0402") | tonumber)}])}}}}'
}

holiday_api() {
  echo "HOLIDAY_API $1" >> "$T/calls"
  local n
  n=$(cat "$T/hapi_n" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$T/hapi_n"
  if [ "$n" -lt "${FAKE_HOLIDAY_FAILS:-0}" ]; then return 1; fi
  if [ "$1" = "${FAKE_HOLIDAY_FAIL_YEAR:-}" ]; then return 1; fi
  case "${FAKE_HOLIDAY_MODE:-ok}" in
    fail) return 1 ;;
    badcode) echo '{"response":{"header":{"resultCode":"30","resultMsg":"SERVICE_KEY_IS_NOT_REGISTERED_ERROR"}}}' ;;
    xml) echo '<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>' ;;
    few) fake_holidays "$1" 3 ;;
    *)
      if [ "$1" -gt "${FAKE_HOLIDAY_MAX_YEAR:-9999}" ]; then
        echo '{"response":{"header":{"resultCode":"00"},"body":{"items":"","totalCount":0}}}'
      else
        fake_holidays "$1" 15
      fi
      ;;
  esac
}
