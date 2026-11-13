# lib.sh 마지막에 source 되어 네트워크 함수를 대체한다. 모든 호출은 $T/calls 에 기록된다.
# 동작 제어 환경변수:
#   FAKE_CREATE_FAILS=N   처음 N번의 POST /pods 실패
#   FAKE_POD_STATUS       GET /pods/{id}: RUNNING(기본) | EXITED 등 | GONE(404) | APIDOWN(오류)
#   FAKE_DELETE_RC        DELETE 반환값 (기본 0)
#   FAKE_VLLM_CODE        vllm_status 기본 응답 (기본 200)
#   FAKE_VLLM_BAD_HOST    이 host 에 대해서만 000 응답
sleep_s() { echo "SLEEP $1" >> "$T/calls"; }
notify()  { echo "NOTIFY $1" >> "$T/calls"; }

rp() {
  echo "RP $1 $2" >> "$T/calls"
  case "$1 $2" in
    "POST /pods")
      local n
      n=$(cat "$T/create_n" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$T/create_n"
      echo "STAGE $(jq -r 'if has("networkVolumeId") then 1 else 2 end' <<<"$3")" >> "$T/calls"
      if [ "$n" -lt "${FAKE_CREATE_FAILS:-0}" ]; then echo '{"error":"no instances available"}'; return 1; fi
      echo "{\"id\":\"pod$((n + 1))\",\"costPerHr\":0.59,\"machine\":{\"gpuTypeId\":\"NVIDIA RTX A6000\",\"dataCenterId\":\"EU-RO-1\"}}"
      ;;
    "GET /pods/"*)
      case "${FAKE_POD_STATUS:-RUNNING}" in
        GONE) return 4 ;;
        APIDOWN) return 1 ;;
        *) echo "{\"desiredStatus\":\"${FAKE_POD_STATUS:-RUNNING}\"}" ;;
      esac
      ;;
    "DELETE /pods/"*) return "${FAKE_DELETE_RC:-0}" ;;
  esac
}

vllm_status() {
  echo "VLLM $1" >> "$T/calls"
  if [ -n "${FAKE_VLLM_BAD_HOST:-}" ] && [ "$1" = "$FAKE_VLLM_BAD_HOST" ]; then echo 000; return; fi
  echo "${FAKE_VLLM_CODE:-200}"
}
