#!/usr/bin/env bash
# 공통 테스트 도우미. 각 테스트는 run_tests 가 서브셸에서 setup 후 실행한다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/ec2/bin"

setup() {
  T=$(mktemp -d)
  export T
  export VOC_HOME="$T/home" LOG_FILE="$T/pod.log" LOCK_FILE="$T/lock" UPSTREAM_CONF="$T/upstream.conf"
  export VOC_NO_RELOAD=1 VOC_STUB="$ROOT/tests/stub.sh" VOC_TODAY=2026-11-16
  export FAKE_CLOCK=1 READY_POLL_SEC=15 READY_TIMEOUT_SEC=60 CREATE_RETRIES=3 CREATE_RETRY_SEC=600
  mkdir -p "$VOC_HOME/state"
  printf '# comment\nNVIDIA RTX A6000\n\nNVIDIA A40\nNVIDIA L40\n' > "$VOC_HOME/gpu-priority.txt"
  : > "$VOC_HOME/holidays.txt"
  cat > "$VOC_HOME/.env" <<'EOT'
RUNPOD_API_KEY=test-runpod
VLLM_API_KEY=test-vllm
HF_TOKEN=test-hf
VLLM_IMAGE=vllm/vllm-openai:v9.9.9
MODEL_ID=org/test-model
MAX_MODEL_LEN=32768
EOT
  : > "$T/calls"
}

run_tests() {
  local rc=0 t
  for t in "$@"; do
    if ( setup; "$t" ); then echo "PASS $t"; else echo "FAIL $t"; rc=1; fi
  done
  return "$rc"
}

fail()            { echo "  ASSERT: $*" >&2; exit 1; }
assert_eq()       { [ "$1" = "$2" ] || fail "$3: expected [$2] got [$1]"; }
assert_file_has() { grep -qF -- "$2" "$1" || fail "$1 does not contain [$2]"; }
assert_no_file()  { [ ! -e "$1" ] || fail "$1 should not exist"; }
events()          { [ -s "$LOG_FILE" ] && jq -r '.event + ":" + .result' "$LOG_FILE" | paste -sd' ' - || true; }
calls_count()     { grep -cF -- "$1" "$T/calls" || true; }
last()            { tail -n1 "$LOG_FILE" | jq -r "$1"; }
