# VOC LLM 인프라 (AWS 중계 + RunPod 추론) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 고객사 VOC 시스템이 고정 HTTPS 주소 하나로 LLM을 호출하게 한다. RunPod GPU Pod는 평일 08:30~18:00에만 자동으로 운영하고, 업무시간에는 감시와 자동 복구를 하며, AWS 중계서버의 자원과 생존 여부도 감시한다.

**Architecture:**
- AWS EC2(t3.small, 서울)의 nginx가 고객사 키를 검증한 뒤 RunPod proxy URL로 프록시한다.
- cron으로 실행되는 bash 스크립트 3개(start, stop, health)가 RunPod REST API로 Pod를 생성, 삭제, 감시하고, `upstream.conf`를 바꿔서 연결 대상을 전환한다.
- 시작, 종료, 감시 이벤트는 JSON Lines로 기록한다.
- 서버 자원과 생존 여부는 CloudWatch, Route 53 health check, EventBridge로 감시하고 SNS로 알린다.

**Tech Stack:**
- bash, jq, curl, flock, nginx 1.24 (Ubuntu 24.04)
- certbot, AWS CLI v2, CloudWatch Agent
- RunPod REST API v1, vLLM OpenAI 호환 서버
- Python 3.12 stdlib (평가 스크립트)

**설계 문서 (스펙):** `README.md`, `aws-설계.md`, `runpod-설계.md` (이 저장소 루트)

## Global Constraints

- RunPod는 `cloudType: "SECURE"`만 사용한다. Community, Vast.ai에는 VOC 데이터를 절대 넣지 않는다.
- GPU 우선순위(비용 순): `NVIDIA RTX A6000` → `NVIDIA A40` → `NVIDIA L40` → `NVIDIA RTX 6000 Ada Generation` → `NVIDIA L40S` → RTX PRO 6000 MIG 48GB (ID는 Task 7에서 확인)
- 고객사에 노출하는 모델 이름은 항상 `voc-llm`이다 (`--served-model-name voc-llm`).
- 양자화는 W4A16 계열(AWQ, compressed-tensors w4a16)만 쓴다. FP8 가중치와 FP8 KV cache는 쓰지 않는다(`--kv-cache-dtype auto`).
- vLLM 이미지는 버전 태그를 고정한다. `latest`는 금지한다.
- 시간대는 Asia/Seoul이고, cron 시각은 KST 기준이다.
  - start: 평일 08:30
  - stop: 평일 18:00
  - health: 평일 09:00~17:58, 2분 간격
- 로그: `/var/log/voc-llm/pod.log`에 JSON Lines로 기록한다. `event`(START, STOP, HEALTH), `ts`, `result` 필드는 필수다.
- 휴일 판정 규칙은 다음 세 가지다.
  - `holidays.txt`(수동 휴무일)는 항상 적용한다.
  - `holidays-api.txt`(공휴일 API)는 마지막 갱신이 성공했을 때만 적용한다.
  - 갱신에 실패한 주(`state/holiday_sync_failed` 존재)는 평일에 모두 운영한다.
- 기동 대기는 최대 25분(1500초)이다. Network Volume 1단계 생성은 3회 시도하고 간격은 10분이다. health는 연속 3회 실패하면 장애로 판정하고, 자동 복구는 하루 최대 3회까지 한다.
- 비밀값(RunPod 키, vLLM 키, HF 토큰, 고객사 키)은 git에 넣지 않는다. 서버에서는 권한 600으로 보관한다.
- SNS 메일 제목(`--subject`)은 ASCII만 쓴다. 본문은 한국어로 써도 된다.
- bash 테스트는 **Linux**에서 실행한다(WSL Ubuntu 또는 EC2). `flock`이 필요해서 Windows Git Bash에서는 동작하지 않는다. 필요한 도구: `bash`, `jq`(1.6 이상), `flock`, `awk`
- 커밋 메시지 끝에 다음 줄을 붙인다: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## File Structure

```
voc-llm-infra/
├── README.md, aws-설계.md, runpod-설계.md      # 스펙 (기존)
├── .gitignore
├── ec2/                                        # EC2에 설치되는 모든 것
│   ├── bin/lib.sh                              # 공통 함수: 로그, 상태, upstream, RunPod API, start/stop/health 로직
│   ├── bin/pod-start.sh                        # 잠금 + 공휴일 + do_start
│   ├── bin/pod-stop.sh                         # 잠금 + do_stop (공휴일 무시)
│   ├── bin/pod-health.sh                       # 비차단 잠금 + 공휴일 + do_health
│   ├── bin/holiday-sync.sh                     # 매주 월 07:00 공휴일 API 갱신 (do_holiday_sync)
│   ├── gpu-priority.txt                        # GPU ID 우선순위
│   ├── holidays.txt                            # 수동 휴무일 (회사 자체 휴무)
│   ├── .env.example                            # 서버 .env 템플릿
│   ├── conf/nginx/voc-llm.conf.tmpl            # envsubst 템플릿
│   ├── conf/nginx/client_keys.conf.example
│   ├── conf/cron/voc-llm
│   ├── conf/logrotate/voc-llm
│   ├── conf/systemd/nginx-override.conf
│   ├── conf/cloudwatch/amazon-cloudwatch-agent.json
│   └── install.sh                              # EC2에서 root로 실행 (멱등)
├── tests/                                      # bash 테스트 (네트워크 호출은 stub)
│   ├── helper.sh, stub.sh, run.sh
│   ├── test_lib.sh, test_start.sh, test_stop.sh, test_health.sh, test_holiday.sh
├── infra/                                      # 관리자 PC에서 1회 실행하는 AWS CLI 스크립트
│   ├── aws.env.example
│   ├── aws-provision.sh                        # IAM, SG, EC2, EIP, SNS(서울)
│   └── aws-monitoring.sh                       # CloudWatch 알람, Route 53 HC, EventBridge, SNS(us-east-1)
├── runpod/
│   ├── models.txt                              # 후보 모델 HF repo 4개 (Task 7에서 확정)
│   └── seed-models.sh                          # Network Volume에 모델 사전 다운로드
└── eval/
    ├── run_eval.py                             # 모델별 샘플 실행, 지연과 속도 측정, 블라인드 CSV 생성
    └── test_run_eval.py
```

테스트 방식:
- `lib.sh`의 마지막 줄은 `VOC_STUB` 환경변수가 가리키는 파일을 source한다. 테스트는 이 경로로 네트워크 함수(`rp`, `vllm_status`, `notify`, `sleep_s`)를 stub으로 바꾼다.
- 경로(`VOC_HOME`, `LOG_FILE`, `LOCK_FILE`, `UPSTREAM_CONF`)와 시간 값(`READY_*`, `CREATE_*`)은 모두 환경변수로 덮어쓸 수 있다.
- 실제 RunPod 호출은 Task 8 통합 검증에서 확인한다.

---

### Task 1: 저장소 초기화, 테스트 하네스, lib.sh 기본 함수

**Files:**
- Create: `.gitignore`, `ec2/gpu-priority.txt`, `ec2/holidays.txt`, `ec2/.env.example`
- Create: `ec2/bin/lib.sh`
- Create: `tests/helper.sh`, `tests/stub.sh`, `tests/run.sh`, `tests/test_lib.sh`

**Interfaces:**
- Produces (lib.sh):
  - 변수: `VOC_HOME`, `STATE_DIR`, `LOG_FILE`, `LOCK_FILE`, `UPSTREAM_CONF`, `RUNPOD_API`, `READY_POLL_SEC`, `READY_TIMEOUT_SEC`, `CREATE_RETRIES`, `CREATE_RETRY_SEC`, `HEALTH_FAIL_LIMIT`, `MAX_RECOVER`
  - `now_iso`: 출력 `2026-11-16T08:30:00+09:00`
  - `now_epoch`, `today` (`YYYY-MM-DD`, `VOC_TODAY`로 덮어쓰기 가능)
  - `is_holiday`: 반환값 0이면 공휴일
  - `sleep_s SEC`
  - `log_event EVENT RESULT [jq --arg/--argjson ...]`: `$LOG_FILE`에 JSON 한 줄 추가
  - `notify SUBJECT MESSAGE`: `SNS_TOPIC_ARN`이 비어 있으면 아무것도 하지 않는다
  - `nginx_reload`: `VOC_NO_RELOAD`가 비어 있지 않으면 아무것도 하지 않는다
  - `upstream_on HOST`, `upstream_off`
  - `rp METHOD PATH [JSON]`: 본문은 stdout, 반환값 0=2xx, 4=404, 1=그 외
  - `vllm_status HOST`: HTTP 코드를 stdout으로 출력 (네트워크 오류는 `000`)
  - `pod_spec STAGE`: STAGE는 1(볼륨 사용) 또는 2(볼륨 없음). Pod 생성 JSON을 stdout으로 출력
  - `pod_id_of JSON`: id를 출력. 없으면 0이 아닌 값을 반환
- Produces (tests/helper.sh): `setup`, `run_tests`, `fail`, `assert_eq`, `assert_file_has`, `assert_no_file`, `events`, `calls_count`, 변수 `ROOT`, `BIN`, `T`

- [ ] **Step 1: git 저장소 초기화와 정적 파일 작성**

```bash
cd /mnt/c/project/voc-llm-infra   # WSL 기준 경로
git init
mkdir -p ec2/bin ec2/conf tests infra runpod eval
```

`.gitignore` (이미 만들어 둠. 내용 확인만 한다. `ec2/.env`에는 실제 공휴일 API 키가 들어 있으므로 반드시 git에서 제외되어야 한다):
```gitignore
# 비밀값과 고객 데이터
.env
ec2/.env
infra/aws.env
infra/aws.out
eval/samples.jsonl
eval/results/
__pycache__/
```

`ec2/gpu-priority.txt`:
```text
# RunPod gpuTypeId, 위에서부터 우선 (비용 순). '#' 줄과 빈 줄은 무시된다.
# RTX PRO 6000 MIG 48GB 의 ID는 Task 7에서 확인한 뒤 맨 아래에 추가한다.
NVIDIA RTX A6000
NVIDIA A40
NVIDIA L40
NVIDIA RTX 6000 Ada Generation
NVIDIA L40S
```

`ec2/holidays.txt`:
```text
# 수동 휴무일 (회사 자체 휴무일 등). YYYY-MM-DD 한 줄에 하나. 공휴일 API 성공 여부와 관계없이 항상 적용된다.
# 법정공휴일, 대체공휴일, 임시공휴일은 holiday-sync.sh 가 자동 반영하므로 넣지 않는다.
```

`ec2/.env.example`:
```bash
# /opt/voc-llm/.env (권한 600). 값에 공백이나 특수문자가 있으면 작은따옴표로 감싼다.
DOMAIN=llm-voc.example.com
CERT_EMAIL=admin@example.com
RUNPOD_API_KEY=
VLLM_API_KEY=
HF_TOKEN=
NETWORK_VOLUME_ID=
VLLM_IMAGE=vllm/vllm-openai:v0.0.0
MODEL_ID=google/gemma-4-31B-it-qat-w4a16-ct
MAX_MODEL_LEN=32768
VLLM_EXTRA_ARGS=''
SNS_TOPIC_ARN=
SNS_REGION=ap-northeast-2
# 공공데이터포털 '한국천문연구원_특일 정보' 일반 인증키 (Decoding 값)
HOLIDAY_API_KEY=
```

- [ ] **Step 2: 테스트 하네스 작성**

`tests/helper.sh`:
```bash
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
  export READY_POLL_SEC=15 READY_TIMEOUT_SEC=60 CREATE_RETRIES=3 CREATE_RETRY_SEC=600
  mkdir -p "$VOC_HOME/state"
  printf '# comment\nNVIDIA RTX A6000\n\nNVIDIA A40\nNVIDIA L40\n' > "$VOC_HOME/gpu-priority.txt"
  : > "$VOC_HOME/holidays.txt"
  cat > "$VOC_HOME/.env" <<'EOF'
RUNPOD_API_KEY=test-runpod
VLLM_API_KEY=test-vllm
HF_TOKEN=test-hf
NETWORK_VOLUME_ID=vol-test
VLLM_IMAGE=vllm/vllm-openai:v9.9.9
MODEL_ID=org/test-model
MAX_MODEL_LEN=32768
EOF
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
```

`tests/stub.sh`:
```bash
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
```

`tests/run.sh`:
```bash
#!/usr/bin/env bash
# 모든 테스트 실행: bash tests/run.sh
cd "$(dirname "$0")"
rc=0
for f in test_*.sh; do
  echo "== $f"
  bash "$f" || rc=1
done
exit "$rc"
```

- [ ] **Step 3: 실패하는 테스트 작성**

`tests/test_lib.sh`:
```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
lib() { ( . "$BIN/lib.sh"; "$@" ); }

t_pod_spec_stage1() {
  local j; j=$(lib pod_spec 1)
  assert_eq "$(jq -r .cloudType <<<"$j")" SECURE "cloudType"
  assert_eq "$(jq -r .networkVolumeId <<<"$j")" vol-test "networkVolumeId"
  assert_eq "$(jq -r .volumeMountPath <<<"$j")" /workspace "volumeMountPath"
  assert_eq "$(jq -r .env.HF_HOME <<<"$j")" /workspace/hf "HF_HOME"
  assert_eq "$(jq -r .env.VLLM_API_KEY <<<"$j")" test-vllm "VLLM_API_KEY"
  assert_eq "$(jq -r '.gpuTypeIds|join(",")' <<<"$j")" "NVIDIA RTX A6000,NVIDIA A40,NVIDIA L40" "gpu order, comments/blank ignored"
  assert_eq "$(jq -r .gpuTypePriority <<<"$j")" custom "gpuTypePriority"
  assert_eq "$(jq -r .imageName <<<"$j")" "vllm/vllm-openai:v9.9.9" "image"
  assert_eq "$(jq -r '.ports|join(",")' <<<"$j")" "8000/http" "ports"
  assert_eq "$(jq -r '.dockerStartCmd|join(" ")' <<<"$j")" \
    "--model org/test-model --served-model-name voc-llm --host 0.0.0.0 --port 8000 --max-model-len 32768 --gpu-memory-utilization 0.90 --kv-cache-dtype auto" "dockerStartCmd"
}

t_pod_spec_stage2() {
  local j; j=$(lib pod_spec 2)
  assert_eq "$(jq -r 'has("networkVolumeId")' <<<"$j")" false "no volume in stage 2"
  assert_eq "$(jq -r 'has("volumeMountPath")' <<<"$j")" false "no mount in stage 2"
  assert_eq "$(jq -r .env.HF_HOME <<<"$j")" /root/.cache/huggingface "HF_HOME stage 2"
}

t_pod_spec_extra_args() {
  local j; j=$(VLLM_EXTRA_ARGS='--limit-mm-per-prompt {"image":0}' lib pod_spec 1)
  assert_eq "$(jq -r '.dockerStartCmd[-2:]|join(" ")' <<<"$j")" '--limit-mm-per-prompt {"image":0}' "extra args appended"
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

t_repo_gpu_priority_first_is_a6000() {
  assert_eq "$(grep -v '^#' "$ROOT/ec2/gpu-priority.txt" | grep -v '^$' | head -1)" "NVIDIA RTX A6000" "repo gpu-priority first line"
}

run_tests t_pod_spec_stage1 t_pod_spec_stage2 t_pod_spec_extra_args t_upstream_on_off t_log_event t_holiday t_repo_gpu_priority_first_is_a6000
```

- [ ] **Step 4: 테스트 실패 확인**

Run: `bash tests/test_lib.sh`
Expected: 모두 `FAIL`. `ec2/bin/lib.sh: No such file or directory` 오류가 난다.

- [ ] **Step 5: lib.sh 기본 함수 구현**

`ec2/bin/lib.sh`:
```bash
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
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `bash tests/test_lib.sh`
Expected: 7개 모두 `PASS`, 종료 코드 0

- [ ] **Step 7: 커밋**

```bash
git add .gitignore README.md aws-설계.md runpod-설계.md docs ec2 tests
git commit -m "feat: lib.sh 기본 함수와 bash 테스트 하네스"
```

---

### Task 2: pod-start.sh (Pod 생성, GPU fallback, 기동 대기, START 로그)

**Files:**
- Modify: `ec2/bin/lib.sh` (스텁 로딩 줄 바로 위에 `create_pod`, `do_start` 추가)
- Create: `ec2/bin/pod-start.sh`
- Test: `tests/test_start.sh`

**Interfaces:**
- Consumes: Task 1의 `rp`, `pod_spec`, `pod_id_of`, `vllm_status`, `upstream_on/off`, `log_event`, `notify`, `sleep_s`, `now_*`
- Produces:
  - `create_pod`: 반환값 0이면 성공. 성공하면 `$STATE_DIR/created.json`을 기록하고 전역변수 `CREATE_STAGE`(1|2), `CREATE_FAILS`(정수)를 설정한다
  - `do_start TRIGGER`: TRIGGER는 `cron`, `manual`, `health` 중 하나. 반환값 0이면 성공
  - 성공하면 `$STATE_DIR/current_pod`를 기록한다. JSON 키: `pod_id`, `gpu`, `datacenter`, `cost_per_hr`(number), `started_at`(iso), `created_epoch`(number), `endpoint`
  - TRIGGER가 `health`가 아니면 당일 `recover_*`, `gave_up_*` 파일을 삭제한다
  - START 로그 result: `ok`, `failed_no_gpu`, `failed_not_ready`, `failed_reload`, `skipped_holiday`, `already_running`
- `pod-start.sh [--force]`: `--force`는 공휴일 체크를 건너뛴다

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_start.sh`:
```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
start() { bash "$BIN/pod-start.sh" "$@"; }

t_start_ok() {
  start || fail "pod-start should succeed"
  assert_eq "$(events)" "START:ok" "events"
  assert_eq "$(last .pod_id)" pod1 "pod_id"
  assert_eq "$(last .gpu)" "NVIDIA RTX A6000" "gpu"
  assert_eq "$(last .datacenter)" EU-RO-1 "datacenter"
  assert_eq "$(last .stage)" 1 "stage"
  assert_eq "$(last .retries)" 0 "retries"
  assert_eq "$(last .cost_per_hr)" 0.59 "cost"
  assert_eq "$(last .model)" org/test-model "model"
  assert_eq "$(last .endpoint)" "https://pod1-8000.proxy.runpod.net" "endpoint"
  assert_file_has "$UPSTREAM_CONF" "proxy_pass https://pod1-8000.proxy.runpod.net;"
  assert_eq "$(jq -r .pod_id "$VOC_HOME/state/current_pod")" pod1 "state pod_id"
  assert_eq "$(jq -r '.created_epoch|type' "$VOC_HOME/state/current_pod")" number "created_epoch type"
}

t_start_fallback_to_stage2() {
  FAKE_CREATE_FAILS=3 start || fail "should succeed in stage 2"
  assert_eq "$(last .result)" ok "result"
  assert_eq "$(last .stage)" 2 "stage"
  assert_eq "$(last .retries)" 3 "retries"
  assert_eq "$(last .pod_id)" pod4 "pod_id"
  assert_eq "$(calls_count 'STAGE 1')" 3 "stage1 attempts"
  assert_eq "$(calls_count 'STAGE 2')" 1 "stage2 attempts"
  assert_eq "$(calls_count 'SLEEP 600')" 2 "retry waits between stage1 attempts"
}

t_start_no_gpu() {
  FAKE_CREATE_FAILS=99 start && fail "should fail"
  assert_eq "$(events)" "START:failed_no_gpu" "events"
  assert_eq "$(last .retries)" 4 "attempts"
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

t_start_resets_recover_counters() {
  echo 3 > "$VOC_HOME/state/recover_20261116"
  touch "$VOC_HOME/state/gave_up_20261116"
  start --force
  assert_no_file "$VOC_HOME/state/recover_20261116"
  assert_no_file "$VOC_HOME/state/gave_up_20261116"
}

run_tests t_start_ok t_start_fallback_to_stage2 t_start_no_gpu t_start_not_ready_deletes_pod \
  t_start_skips_holiday t_start_force_on_holiday t_start_already_running t_start_resets_recover_counters
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `bash tests/test_start.sh`
Expected: 모두 `FAIL`. `pod-start.sh: No such file or directory` 오류가 난다.

- [ ] **Step 3: lib.sh에 create_pod, do_start 추가**

`ec2/bin/lib.sh`의 `# --- 이 아래에 Task 2~4 함수를 추가한다 ...` 줄 바로 아래에 추가한다(스텁 로딩 `if` 블록보다 위):
```bash
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

# do_start TRIGGER(cron|manual|health)
do_start() {
  local trigger=$1 requested_at t0 created_at created_epoch pod info id gpu dc cost host waited code
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

  # 생성 응답에 GPU/DC 정보가 없을 수 있어 GET 결과와 합친다
  info=$(rp GET "/pods/$id" 2>/dev/null) || info='{}'
  info=$(jq -cs '.[0] * .[1]' <<<"$pod$info" 2>/dev/null) || info=$pod
  gpu=$(jq -r '.machine.gpuTypeId // .machine.gpuDisplayName // .gpuTypeId // "unknown"' <<<"$info")
  dc=$(jq -r '.machine.dataCenterId // .dataCenterId // "unknown"' <<<"$info")
  cost=$(jq -r '.costPerHr // .adjustedCostPerHr // 0' <<<"$info")
  host="$id-8000.proxy.runpod.net"

  waited=0
  while :; do
    code=$(vllm_status "$host")
    if [ "$code" = 200 ]; then break; fi
    if [ "$waited" -ge "$READY_TIMEOUT_SEC" ]; then
      rp DELETE "/pods/$id" >/dev/null 2>&1 || true
      upstream_off || true
      log_event START failed_not_ready --arg trigger "$trigger" --arg requested_at "$requested_at" \
        --arg pod_id "$id" --arg gpu "$gpu" --argjson waited_sec "$waited" --arg last_http "$code"
      notify "START failed: vLLM not ready" "Pod $id ($gpu)가 ${READY_TIMEOUT_SEC}초 안에 준비되지 않아 삭제했습니다. 마지막 응답: $code. RunPod 콘솔에서 Pod가 지워졌는지 확인하세요."
      return 1
    fi
    sleep_s "$READY_POLL_SEC"
    waited=$((waited + READY_POLL_SEC))
  done

  if ! upstream_on "$host"; then
    rp DELETE "/pods/$id" >/dev/null 2>&1 || true
    upstream_off || true
    log_event START failed_reload --arg trigger "$trigger" --arg pod_id "$id" --arg gpu "$gpu"
    notify "START failed: nginx reload" "nginx reload 실패로 Pod $id를 삭제했습니다. 'nginx -t' 결과를 확인하세요."
    return 1
  fi

  jq -n --arg pod_id "$id" --arg gpu "$gpu" --arg datacenter "$dc" --argjson cost_per_hr "$cost" \
    --arg started_at "$created_at" --argjson created_epoch "$created_epoch" --arg endpoint "https://$host" \
    '$ARGS.named' > "$STATE_DIR/current_pod"
  echo 0 > "$STATE_DIR/health_fail"
  log_event START ok --arg trigger "$trigger" --arg requested_at "$requested_at" --arg ready_at "$(now_iso)" \
    --argjson ready_sec "$(($(now_epoch) - t0))" --arg pod_id "$id" --arg gpu "$gpu" --arg datacenter "$dc" \
    --argjson stage "$CREATE_STAGE" --argjson retries "$CREATE_FAILS" --argjson cost_per_hr "$cost" \
    --arg model "$MODEL_ID" --arg endpoint "https://$host"
}
```

- [ ] **Step 4: pod-start.sh 작성**

`ec2/bin/pod-start.sh`:
```bash
#!/usr/bin/env bash
# 평일 08:30 cron. 수동: pod-start.sh --force (공휴일 무시)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock 9

trigger=cron
if [ "${1:-}" = "--force" ]; then trigger=manual; fi

if [ "$trigger" = cron ] && is_holiday; then
  log_event START skipped_holiday
  exit 0
fi
if [ -f "$STATE_DIR/current_pod" ]; then
  log_event START already_running --arg pod_id "$(jq -r .pod_id "$STATE_DIR/current_pod")"
  exit 0
fi
do_start "$trigger"
```

Run: `chmod +x ec2/bin/*.sh`

- [ ] **Step 5: 테스트 통과 확인**

Run: `bash tests/test_start.sh && bash tests/test_lib.sh`
Expected: 8개 + 7개 모두 `PASS`

- [ ] **Step 6: 커밋**

```bash
git add ec2/bin tests/test_start.sh
git commit -m "feat: pod-start.sh GPU fallback, 기동 대기, START 로그"
```

---

### Task 3: pod-stop.sh (upstream 차단, Pod 삭제, STOP 로그와 추정 비용)

**Files:**
- Modify: `ec2/bin/lib.sh` (스텁 로딩 줄 위에 `do_stop` 추가)
- Create: `ec2/bin/pod-stop.sh`
- Test: `tests/test_stop.sh`

**Interfaces:**
- Consumes: `current_pod` JSON(Task 2), `rp`, `upstream_off`, `log_event`, `notify`, `sleep_s`
- Produces:
  - `do_stop LABEL`: LABEL은 `ok` 또는 `replaced`. 반환값 0이면 삭제 성공 또는 Pod 없음, 1이면 삭제 실패(`current_pod` 유지)
  - STOP 로그 필드: `pod_id`, `gpu`, `started_at`, `uptime_hr`(number), `cost_per_hr`, `est_cost_usd`(number)
  - result: `ok`, `replaced`, `no_pod`, `failed_delete`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_stop.sh`:
```bash
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
}

run_tests t_stop_ok t_stop_no_pod t_stop_delete_404_counts_as_deleted t_stop_delete_fail_keeps_state t_stop_deletes_on_holiday
```

`t_stop_deletes_on_holiday`: stop 은 공휴일을 확인하지 않는다(사람 결정). 공휴일에 `--force` 등으로 기동된 Pod 나 남은 Pod 도 반드시 지워야 과금이 멈춘다. Pod 가 없으면 do_stop 이 `no_pod` 를 기록한다.

- [ ] **Step 2: 테스트 실패 확인**

Run: `bash tests/test_stop.sh`
Expected: 모두 `FAIL`. `pod-stop.sh: No such file or directory` 오류가 난다.

- [ ] **Step 3: lib.sh에 do_stop 추가 (스텁 로딩 줄 위)**

```bash
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
```

- [ ] **Step 4: pod-stop.sh 작성**

`ec2/bin/pod-stop.sh`:
```bash
#!/usr/bin/env bash
# 평일 18:00 cron (+ 19:30 안전망). 공휴일에도 항상 실행한다(남은 Pod 삭제)
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock 9

do_stop ok
```

Run: `chmod +x ec2/bin/pod-stop.sh`

- [ ] **Step 5: 테스트 통과 확인**

Run: `bash tests/run.sh`
Expected: test_lib, test_start, test_stop 모두 `PASS`, 종료 코드 0

- [ ] **Step 6: 커밋**

```bash
git add ec2/bin tests/test_stop.sh
git commit -m "feat: pod-stop.sh 삭제 재시도, STOP 로그와 추정 비용"
```

---

### Task 4: pod-health.sh (업무시간 생존 감시와 자동 복구)

**Files:**
- Modify: `ec2/bin/lib.sh` (스텁 로딩 줄 위에 `recover_count`, `health_recover`, `do_health` 추가)
- Create: `ec2/bin/pod-health.sh`
- Test: `tests/test_health.sh`

**Interfaces:**
- Consumes: `do_start health`, `do_stop replaced`(Task 2, 3), `rp`, `vllm_status`
- Produces:
  - 상태 파일: `state/health_fail`(정수), `state/recover_YYYYMMDD`(정수), `state/gave_up_YYYYMMDD`(빈 파일), `state/maintenance`(운영자가 만듦)
  - HEALTH 로그 result: `degraded`, `down`, `recovered_self`, `no_pod`, `gave_up`
  - 알림 제목: `RunPod DOWN`, `RunPod recovered`, `RunPod recovery failed`, `RunPod recovery gave up`

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_health.sh`:
```bash
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
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `bash tests/test_health.sh`
Expected: 모두 `FAIL`. `pod-health.sh: No such file or directory` 오류가 난다.

- [ ] **Step 3: lib.sh에 감시 함수 추가 (스텁 로딩 줄 위)**

```bash
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
  if [ -f "$STATE_DIR/maintenance" ] || [ -f "$STATE_DIR/gave_up_$day" ]; then return 0; fi

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
    status=$(jq -r '.desiredStatus // "RUNNING"' <<<"$st" 2>/dev/null || echo RUNNING)
  fi

  if [ -n "$status" ] && [ "$status" != RUNNING ]; then
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
```

- [ ] **Step 4: pod-health.sh 작성**

`ec2/bin/pod-health.sh`:
```bash
#!/usr/bin/env bash
# 평일 09:00~17:58, 2분 간격 cron. 기동/복구 진행 중(잠금 보유)이면 이번 회차는 건너뛴다.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if is_holiday; then exit 0; fi
do_health
```

Run: `chmod +x ec2/bin/pod-health.sh`

- [ ] **Step 5: 테스트 통과 확인**

Run: `bash tests/run.sh`
Expected: 4개 파일의 테스트(7 + 8 + 5 + 11 = 31개)가 모두 `PASS`, 종료 코드 0

- [ ] **Step 6: 커밋**

```bash
git add ec2/bin tests/test_health.sh
git commit -m "feat: pod-health.sh 업무시간 감시와 자동 복구"
```

---

### Task 4-1: 공휴일 자동 갱신 (holiday-sync.sh)과 휴일 판정 규칙 변경

**Files:**
- Modify: `ec2/bin/lib.sh`
  - 상단 변수 블록에 `HOLIDAY_*` 3개 추가
  - Task 1의 `is_holiday` 한 줄을 교체
  - 스텁 로딩 줄 위에 `holiday_api`, `holiday_dates`, `do_holiday_sync` 추가
- Modify: `tests/stub.sh` (`holiday_api`, `fake_holidays` 추가)
- Create: `ec2/bin/holiday-sync.sh`
- Test: `tests/test_holiday.sh`

**Interfaces:**
- Consumes: `log_event`, `notify`, `sleep_s`, `today`, `STATE_DIR`, `VOC_HOME`
- Produces:
  - `holiday_api YEAR`: 원본 응답을 stdout으로 출력. 반환값 0이 아니면 네트워크 또는 HTTP 오류
  - `holiday_dates JSON`: `isHoliday=Y`인 날짜를 `YYYY-MM-DD`로 한 줄씩 출력. 정상 응답이 아니거나 0건이면 0이 아닌 값을 반환
  - `do_holiday_sync`: 반환값 0이면 성공. 성공하면 `$VOC_HOME/holidays-api.txt`를 교체하고 `$STATE_DIR/holiday_sync_failed`를 삭제한다. 실패하면 마커를 만들고 알림을 보낸다
  - `is_holiday`: 수동 목록에 있으면 휴일. 그 외에는 실패 마커가 없을 때만 API 목록으로 판정한다
  - 로그: `{"event":"HOLIDAY_SYNC","result":"ok","year":2026,"count":N,"next_year_count":M}` 또는 `result:"failed"`와 `attempts`

- [ ] **Step 1: stub에 공휴일 API 가짜 응답 추가**

`tests/stub.sh` 맨 아래에 추가:
```bash
# FAKE_HOLIDAY_MODE: ok(기본) | fail | badcode | xml | few
# FAKE_HOLIDAY_FAILS=N : 처음 N번 호출 실패
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
```

- [ ] **Step 2: 실패하는 테스트 작성**

`tests/test_holiday.sh`:
```bash
#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
lib()   { ( . "$BIN/lib.sh"; "$@" ); }
sync()  { bash "$BIN/holiday-sync.sh"; }
start() { bash "$BIN/pod-start.sh" "$@"; }
# 경로는 setup 이후에 정해지므로 함수로 계산한다
api()    { echo "$VOC_HOME/holidays-api.txt"; }
marker() { echo "$VOC_HOME/state/holiday_sync_failed"; }

t_sync_ok_this_and_next_year() {
  sync || fail "sync should succeed"
  assert_eq "$(events)" "HOLIDAY_SYNC:ok" "events"
  assert_eq "$(last .count)" 30 "15 + 15 dates"
  assert_eq "$(last .next_year_count)" 15 "next year"
  assert_file_has "$(api)" "2026-12-25"
  assert_file_has "$(api)" "2027-01-01"
  grep -qx 2026-04-02 "$(api)" && fail "isHoliday=N must be excluded"
  assert_no_file "$(marker)"
}

t_sync_next_year_missing_is_ok() {
  FAKE_HOLIDAY_MAX_YEAR=2026 sync || fail "next year empty is not a failure"
  assert_eq "$(last .count)" 15 "this year only"
  assert_eq "$(last .next_year_count)" 0 "next year 0"
}

t_sync_retries_then_ok() {
  FAKE_HOLIDAY_FAILS=2 sync || fail "3rd attempt succeeds"
  assert_eq "$(last .result)" ok "result"
  assert_eq "$(calls_count 'HOLIDAY_API 2026')" 3 "3 attempts this year"
  assert_eq "$(calls_count 'SLEEP 600')" 2 "2 waits"
}

t_sync_fail_sets_marker_and_notifies() {
  FAKE_HOLIDAY_MODE=fail sync && fail "should fail"
  assert_eq "$(events)" "HOLIDAY_SYNC:failed" "events"
  assert_eq "$(last .attempts)" 3 "attempts"
  [ -f "$(marker)" ] || fail "marker must exist"
  assert_eq "$(calls_count 'NOTIFY Holiday sync failed')" 1 "notify"
}

t_sync_bad_responses_fail() {
  local m
  for m in badcode xml few; do
    rm -f "$(marker)" "$T/hapi_n"
    FAKE_HOLIDAY_MODE=$m sync && fail "$m should fail"
    [ -f "$(marker)" ] || fail "$m: marker must exist"
  done
  true
}

t_sync_fail_keeps_old_file() {
  echo 2026-11-16 > "$(api)"
  FAKE_HOLIDAY_MODE=fail sync || true
  assert_eq "$(cat "$(api)")" 2026-11-16 "old api file kept"
}

t_sync_success_clears_marker() {
  touch "$(marker)"
  sync
  assert_no_file "$(marker)"
}

t_api_holiday_skips_start() {
  sync
  VOC_TODAY=2026-12-25 start
  assert_eq "$(last .result)" skipped_holiday "API holiday skips"
}

t_failed_week_runs_on_api_holiday() {
  echo 2026-11-16 > "$(api)"
  touch "$(marker)"
  start || fail "should start on weekday when sync failed"
  assert_eq "$(last .result)" ok "runs despite API holiday"
}

t_manual_holiday_applies_even_when_failed() {
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  touch "$(marker)"
  start
  assert_eq "$(last .result)" skipped_holiday "manual holiday always applies"
}

t_holiday_dates_single_object_item() {
  local j='{"response":{"header":{"resultCode":"00"},"body":{"items":{"item":{"isHoliday":"Y","locdate":20261225}}}}}'
  assert_eq "$(lib holiday_dates "$j")" 2026-12-25 "single item object"
}

t_holiday_dates_empty_items_string() {
  local j='{"response":{"header":{"resultCode":"00"},"body":{"items":"","totalCount":0}}}'
  lib holiday_dates "$j" && fail "empty must return non-zero"
  true
}

run_tests t_sync_ok_this_and_next_year t_sync_next_year_missing_is_ok t_sync_retries_then_ok \
  t_sync_fail_sets_marker_and_notifies t_sync_bad_responses_fail t_sync_fail_keeps_old_file \
  t_sync_success_clears_marker t_api_holiday_skips_start t_failed_week_runs_on_api_holiday \
  t_manual_holiday_applies_even_when_failed t_holiday_dates_single_object_item t_holiday_dates_empty_items_string
```
- [ ] **Step 3: 테스트 실패 확인**

Run: `bash tests/test_holiday.sh`
Expected: 모두 `FAIL`. `holiday-sync.sh: No such file or directory`, `holiday_dates: command not found` 오류가 난다.

- [ ] **Step 4: lib.sh 수정**

① 상단 변수 블록(`MAX_RECOVER=...` 줄 아래)에 추가:
```bash
HOLIDAY_API_URL="${HOLIDAY_API_URL:-https://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/getRestDeInfo}"
HOLIDAY_RETRIES="${HOLIDAY_RETRIES:-3}"
HOLIDAY_RETRY_SEC="${HOLIDAY_RETRY_SEC:-600}"
```

② Task 1의 `is_holiday` 한 줄을 교체:
```bash
# 수동 휴무일은 항상 적용. API 공휴일은 마지막 갱신이 성공했을 때만 적용 (실패한 주는 평일 모두 운영)
is_holiday() {
  if grep -qxF "$(today)" "$VOC_HOME/holidays.txt" 2>/dev/null; then return 0; fi
  if [ -f "$STATE_DIR/holiday_sync_failed" ]; then return 1; fi
  grep -qxF "$(today)" "$VOC_HOME/holidays-api.txt" 2>/dev/null
}
```

③ 스텁 로딩 줄 위에 추가:
```bash
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
    if raw=$(holiday_api "$year") && cur=$(holiday_dates "$raw") && [ "$(wc -l <<<"$cur")" -ge 10 ]; then break; fi
    cur=""
  done
  if [ -z "$cur" ]; then
    touch "$STATE_DIR/holiday_sync_failed"
    log_event HOLIDAY_SYNC failed --argjson year "$year" --argjson attempts "$HOLIDAY_RETRIES"
    notify "Holiday sync failed" "공휴일 API 갱신에 ${HOLIDAY_RETRIES}회 실패했습니다. 다음 갱신이 성공할 때까지 공휴일 판정을 끄고 평일에는 모두 운영합니다(holidays.txt 수동 휴무일은 계속 적용). HOLIDAY_API_KEY 확인 후 holiday-sync.sh 를 수동 실행하세요."
    return 1
  fi
  if raw=$(holiday_api "$next") && nxt=$(holiday_dates "$raw"); then nn=$(wc -l <<<"$nxt"); else nxt=""; fi
  { printf '%s\n' "$cur"; if [ -n "$nxt" ]; then printf '%s\n' "$nxt"; fi; } | sort -u > "$VOC_HOME/holidays-api.txt.tmp"
  mv "$VOC_HOME/holidays-api.txt.tmp" "$VOC_HOME/holidays-api.txt"
  rm -f "$STATE_DIR/holiday_sync_failed"
  log_event HOLIDAY_SYNC ok --argjson year "$year" --argjson count "$(wc -l < "$VOC_HOME/holidays-api.txt")" --argjson next_year_count "$nn"
}
```

- [ ] **Step 5: holiday-sync.sh 작성**

`ec2/bin/holiday-sync.sh`:
```bash
#!/usr/bin/env bash
# 매주 월요일 07:00 cron + install.sh 에서 1회. 수동 재실행 가능.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
do_holiday_sync
```

Run: `chmod +x ec2/bin/holiday-sync.sh`

- [ ] **Step 6: 테스트 통과 확인**

Run: `bash tests/run.sh`
Expected: 5개 파일의 테스트(7 + 8 + 5 + 11 + 12 = 43개)가 모두 `PASS`. 기존 `t_holiday`, `t_start_skips_holiday`, `t_stop_skips_holiday`, `t_health_holiday_skips`도 계속 통과해야 한다. 이 테스트들은 수동 목록을 쓰기 때문이다.

- [ ] **Step 7: 커밋**

```bash
git add ec2/bin tests/stub.sh tests/test_holiday.sh ec2/holidays.txt
git commit -m "feat: 공휴일 API 주간 자동 갱신, 실패한 주는 평일 전부 운영"
```

---

### Task 5: EC2 설정 파일과 install.sh

**Files:**
- Create: `ec2/conf/nginx/voc-llm.conf.tmpl`, `ec2/conf/nginx/client_keys.conf.example`
- Create: `ec2/conf/cron/voc-llm`, `ec2/conf/logrotate/voc-llm`, `ec2/conf/systemd/nginx-override.conf`
- Create: `ec2/conf/cloudwatch/amazon-cloudwatch-agent.json`
- Create: `ec2/install.sh`

**Interfaces:**
- Consumes: `ec2/bin/*.sh`, `ec2/.env.example`, `lib.sh`의 `upstream_off`
- Produces: EC2 경로 `/opt/voc-llm/{bin,state,.env,gpu-priority.txt,holidays.txt}`, `/etc/nginx/conf.d/voc-llm.conf`, `/etc/nginx/voc-llm/{upstream.conf,client_keys.conf}`, `/etc/cron.d/voc-llm`, CloudWatch 네임스페이스 `VOC-LLM`의 지표 `mem_used_percent`, `swap_used_percent`, `disk_used_percent`(차원 `InstanceId`, `path`, `fstype`)

- [ ] **Step 1: nginx 템플릿 작성**

`ec2/conf/nginx/voc-llm.conf.tmpl` (`${DOMAIN}`과 `${VLLM_API_KEY}`만 envsubst로 치환한다):
```nginx
map $http_authorization $client_ok {
    default 0;
    include /etc/nginx/voc-llm/client_keys.conf;
}

server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2m;

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 'ok';
    }

    location /v1/ {
        default_type application/json;
        if ($client_ok = 0) {
            return 401 '{"error":{"message":"invalid api key","type":"unauthorized"}}';
        }

        include /etc/nginx/voc-llm/upstream.conf;

        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_set_header Authorization "Bearer ${VLLM_API_KEY}";
    }

    location / {
        return 404;
    }
}
```

`ec2/conf/nginx/client_keys.conf.example`:
```nginx
# 고객사 API 키. 한 줄에 하나: "Bearer <키>" 1;
# 키 생성: openssl rand -hex 32
"Bearer REPLACE_WITH_CUSTOMER_KEY" 1;
```

- [ ] **Step 2: cron, logrotate, systemd, CloudWatch Agent 설정 작성**

`ec2/conf/cron/voc-llm` (파일 끝에 빈 줄이 반드시 있어야 cron이 마지막 줄을 읽는다):
```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
30 8 * * 1-5     root /opt/voc-llm/bin/pod-start.sh  >> /var/log/voc-llm/cron.log 2>&1
0 18 * * 1-5     root /opt/voc-llm/bin/pod-stop.sh   >> /var/log/voc-llm/cron.log 2>&1
*/2 9-17 * * 1-5 root /opt/voc-llm/bin/pod-health.sh >> /var/log/voc-llm/cron.log 2>&1
0 7 * * 1        root /opt/voc-llm/bin/holiday-sync.sh >> /var/log/voc-llm/cron.log 2>&1

```

`ec2/conf/logrotate/voc-llm`:
```text
/var/log/voc-llm/*.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

`ec2/conf/systemd/nginx-override.conf`:
```ini
[Service]
Restart=on-failure
RestartSec=5
```

`ec2/conf/cloudwatch/amazon-cloudwatch-agent.json`:
```json
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "VOC-LLM",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "swap": { "measurement": ["swap_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"], "drop_device": true }
    }
  }
}
```

- [ ] **Step 3: install.sh 작성**

`ec2/install.sh`:
```bash
#!/usr/bin/env bash
# EC2(Ubuntu 24.04)에서 root 로 실행: sudo bash ec2/install.sh
# 여러 번 실행해도 안전하다. 처음 실행 시 /opt/voc-llm/.env 를 만들고 멈춘다 → 값을 채우고 다시 실행.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
APP=/opt/voc-llm

install -d -m 755 "$APP/bin" "$APP/state" /var/log/voc-llm /etc/nginx/voc-llm
if [ ! -f "$APP/.env" ]; then
  # 로컬에서 미리 채운 ec2/.env(git 제외)가 함께 복사됐으면 그것을, 없으면 템플릿을 쓴다
  if [ -f "$SRC/.env" ]; then install -m 600 "$SRC/.env" "$APP/.env"; else install -m 600 "$SRC/.env.example" "$APP/.env"; fi
  echo "생성됨: $APP/.env  → 빈 값을 채운 뒤 install.sh 를 다시 실행하세요."
  exit 1
fi
set -a; . "$APP/.env"; set +a
: "${DOMAIN:?.env 에 DOMAIN 필요}" "${CERT_EMAIL:?.env 에 CERT_EMAIL 필요}" "${VLLM_API_KEY:?.env 에 VLLM_API_KEY 필요}"

# 시간대 (cron 이 KST 로 동작하도록)
timedatectl set-timezone Asia/Seoul

# 패키지
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx jq curl certbot gettext-base util-linux stress-ng
command -v aws >/dev/null || snap install aws-cli --classic

# 스왑 1GB
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 애플리케이션 파일 (gpu-priority, holidays 는 저장소가 원본이므로 항상 덮어쓴다)
install -m 755 "$SRC"/bin/*.sh "$APP/bin/"
install -m 644 "$SRC/gpu-priority.txt" "$SRC/holidays.txt" "$APP/"

# 인증서 (최초 1회 standalone 발급. 갱신 시 nginx 를 잠깐 멈췄다 다시 띄운다)
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  systemctl stop nginx || true
  certbot certonly --standalone -d "$DOMAIN" -m "$CERT_EMAIL" --agree-tos -n \
    --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
fi

# nginx
rm -f /etc/nginx/sites-enabled/default
envsubst '${DOMAIN} ${VLLM_API_KEY}' < "$SRC/conf/nginx/voc-llm.conf.tmpl" > /etc/nginx/conf.d/voc-llm.conf
chmod 600 /etc/nginx/conf.d/voc-llm.conf
[ -f /etc/nginx/voc-llm/client_keys.conf ] || install -m 600 "$SRC/conf/nginx/client_keys.conf.example" /etc/nginx/voc-llm/client_keys.conf
[ -f /etc/nginx/voc-llm/upstream.conf ] || VOC_NO_RELOAD=1 bash -c ". $APP/bin/lib.sh; upstream_off"
install -D -m 644 "$SRC/conf/systemd/nginx-override.conf" /etc/systemd/system/nginx.service.d/override.conf

# cron, logrotate, journald
install -m 644 "$SRC/conf/cron/voc-llm" /etc/cron.d/voc-llm
install -m 644 "$SRC/conf/logrotate/voc-llm" /etc/logrotate.d/voc-llm
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/size.conf

systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable nginx cron
systemctl restart cron
nginx -t
systemctl restart nginx

# CloudWatch Agent
CWA=/opt/aws/amazon-cloudwatch-agent
if [ ! -x "$CWA/bin/amazon-cloudwatch-agent-ctl" ]; then
  curl -sSfo /tmp/cwa.deb https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
  dpkg -i /tmp/cwa.deb
fi
install -D -m 644 "$SRC/conf/cloudwatch/amazon-cloudwatch-agent.json" "$CWA/etc/amazon-cloudwatch-agent.json"
"$CWA/bin/amazon-cloudwatch-agent-ctl" -a fetch-config -m ec2 -s -c "file:$CWA/etc/amazon-cloudwatch-agent.json"
systemctl enable amazon-cloudwatch-agent

# 공휴일 최초 갱신 (실패해도 설치는 계속. 실패 시 이번 주는 평일 모두 운영)
"$APP/bin/holiday-sync.sh" || echo "공휴일 갱신 실패: HOLIDAY_API_KEY 확인 후 $APP/bin/holiday-sync.sh 재실행"

echo "install 완료. 고객사 키: /etc/nginx/voc-llm/client_keys.conf 수정 후 'systemctl reload nginx'"
```

- [ ] **Step 4: 정적 검증**

Run:
```bash
bash -n ec2/install.sh ec2/bin/*.sh && echo SYNTAX_OK
jq empty ec2/conf/cloudwatch/amazon-cloudwatch-agent.json && echo JSON_OK
DOMAIN=t.example.com VLLM_API_KEY=k envsubst '${DOMAIN} ${VLLM_API_KEY}' < ec2/conf/nginx/voc-llm.conf.tmpl | grep -c '\$client_ok\|\$host\|\$http_authorization'
tail -c1 ec2/conf/cron/voc-llm | od -c | head -1
```
Expected:
- `SYNTAX_OK`와 `JSON_OK`가 출력된다.
- grep 결과가 `3` 이상이다. nginx 변수가 치환되지 않고 남아 있다는 뜻이다.
- 마지막 바이트가 `\n`이다.

(`nginx -t`는 인증서가 필요해서 Task 6에서 EC2에 설치하며 확인한다.)

- [ ] **Step 5: 커밋**

```bash
git add ec2/conf ec2/install.sh
git commit -m "feat: EC2 nginx, cron, logrotate, CloudWatch Agent 설정과 install.sh"
```

---

### Task 6: AWS 리소스 생성과 EC2 설치

**Files:**
- Create: `infra/aws.env.example`, `infra/aws-provision.sh`

**Interfaces:**
- Produces: `infra/aws.out` (gitignore). 키: `INSTANCE_ID`, `EIP`, `SG_ID`, `TOPIC_ARN`. Task 9가 source해서 쓴다

- [ ] **Step 1: 설정 파일 템플릿 작성**

`infra/aws.env.example`:
```bash
# cp infra/aws.env.example infra/aws.env 후 값 입력 (aws.env 는 git 제외)
REGION=ap-northeast-2
KEY_NAME=voc-llm-key            # 이미 만든 EC2 키 페어 이름
ADMIN_CIDR=203.0.113.10/32      # 관리자 공인 IP
CUSTOMER_CIDR=198.51.100.20/32  # 고객사 VOC 서버 공인 IP
ALERT_EMAIL=ops@example.com     # 알림 수신 메일
DOMAIN=llm-voc.example.com
```

- [ ] **Step 2: 프로비저닝 스크립트 작성**

`infra/aws-provision.sh`:
```bash
#!/usr/bin/env bash
# 관리자 PC(AWS CLI v2, jq, 관리자 권한 자격증명)에서 실행. 재실행해도 기존 리소스를 재사용한다.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; set +a
export AWS_DEFAULT_REGION=$REGION

# SNS (서울)
TOPIC=$(aws sns create-topic --name voc-llm-alerts --query TopicArn --output text)

# IAM 역할: CloudWatch Agent + SNS 발행
if ! aws iam get-role --role-name voc-llm-ec2 >/dev/null 2>&1; then
  aws iam create-role --role-name voc-llm-ec2 --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name voc-llm-ec2 --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
  aws iam create-instance-profile --instance-profile-name voc-llm-ec2 >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name voc-llm-ec2 --role-name voc-llm-ec2
  sleep 15   # IAM 전파 대기
fi
aws iam put-role-policy --role-name voc-llm-ec2 --policy-name sns-publish --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$TOPIC\"}]}"

# Security Group (기본 VPC)
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=voc-llm Name=vpc-id,Values="$VPC" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = None ]; then
  SG=$(aws ec2 create-security-group --group-name voc-llm --description "voc-llm relay" --vpc-id "$VPC" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$CUSTOMER_CIDR,Description=customer},{CidrIp=$ADMIN_CIDR,Description=admin}]" \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=certbot}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$ADMIN_CIDR,Description=admin-ssh}]" >/dev/null
  # Route 53 health checker: Task 9 에서 health check 리전을 이 3곳으로 제한한다
  for cidr in $(curl -s https://ip-ranges.amazonaws.com/ip-ranges.json | jq -r \
      '.prefixes[] | select(.service=="ROUTE53_HEALTHCHECKS" and (.region=="us-east-1" or .region=="ap-northeast-1" or .region=="ap-southeast-1")) | .ip_prefix'); do
    aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$cidr,Description=route53-hc}]" >/dev/null
  done
fi

# EC2
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=voc-llm-relay Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$IID" = None ]; then
  AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)
  IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.small --key-name "$KEY_NAME" \
    --security-group-ids "$SG" --iam-instance-profile Name=voc-llm-ec2 \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=voc-llm-relay}]' \
    --query 'Instances[0].InstanceId' --output text)
  aws ec2 wait instance-running --instance-ids "$IID"
fi

# Elastic IP
ALLOC=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=voc-llm --query 'Addresses[0].AllocationId' --output text)
if [ "$ALLOC" = None ]; then
  ALLOC=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=voc-llm}]' --query AllocationId --output text)
fi
aws ec2 associate-address --instance-id "$IID" --allocation-id "$ALLOC" >/dev/null
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)

printf 'INSTANCE_ID=%s\nEIP=%s\nSG_ID=%s\nTOPIC_ARN=%s\n' "$IID" "$EIP" "$SG" "$TOPIC" | tee aws.out
echo "다음: DNS A 레코드 $DOMAIN → $EIP"
```

- [ ] **Step 3: 실행**

Run: `cp infra/aws.env.example infra/aws.env` → 실제 값 입력 → `bash infra/aws-provision.sh`
Expected: 마지막에 `INSTANCE_ID=i-...`, `EIP=x.x.x.x`, `SG_ID=sg-...`, `TOPIC_ARN=arn:aws:sns:ap-northeast-2:...:voc-llm-alerts`가 출력된다.

기본 VPC가 없으면(`VPC=None`) VPC 콘솔에서 "기본 VPC 생성"을 한 뒤 다시 실행한다.

- [ ] **Step 4: DNS 등록**

도메인 관리 화면(사내 DNS 또는 Route 53)에서 `A 레코드: <DOMAIN> → <EIP>`, TTL 300으로 등록한다.

Run: `nslookup <DOMAIN>`
Expected: EIP가 반환된다.

- [ ] **Step 5: EC2에 설치**

```bash
scp -i <키파일> -r ec2 ubuntu@<EIP>:~/
ssh -i <키파일> ubuntu@<EIP>
sudo bash ~/ec2/install.sh          # 1회차: .env 생성 후 종료(exit 1)
sudo nano /opt/voc-llm/.env         # 값 입력
```

`.env`에 넣을 값:
- `DOMAIN`, `CERT_EMAIL`
- `VLLM_API_KEY`: `openssl rand -hex 32`로 생성
- `SNS_TOPIC_ARN`: aws.out의 `TOPIC_ARN`
- RunPod 관련 값은 Task 7에서 채운다

```bash
sudo bash ~/ec2/install.sh          # 2회차: 전체 설치. 최초 설치 시 고객사 키를 무작위 생성해 화면에 1회 출력
```
출력된 고객사 키를 안전한 경로로 고객사에 전달한다. 키 추가/교체는 `/etc/nginx/voc-llm/client_keys.conf` 수정 후 `sudo systemctl reload nginx`. (구현은 feat/task-5 cdc3507 기준. 위 Task 5 본문의 placeholder 예시는 구현에서 대체됨)

- [ ] **Step 6: 설치 결과 검증 (관리자 PC에서)**

```bash
curl -s https://<DOMAIN>/healthz; echo
curl -s -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/v1/models -H 'Authorization: Bearer wrong'
curl -s https://<DOMAIN>/v1/models -H 'Authorization: Bearer <고객사키>'; echo
ssh ubuntu@<EIP> 'timedatectl | grep "Time zone"; swapon --show; systemctl is-enabled nginx cron amazon-cloudwatch-agent'
```
Expected:
- `ok`
- `401`
- `{"error":{"message":"LLM service is available weekdays 09:00-18:00 KST","type":"service_unavailable"}}` (HTTP 503)
- `Asia/Seoul`, `/swapfile 1G`, `enabled` 세 줄

- [ ] **Step 7: 커밋**

```bash
git add infra/aws.env.example infra/aws-provision.sh
git commit -m "feat: AWS 프로비저닝 스크립트 (IAM, SG, EC2, EIP, SNS)"
```

---

### Task 7: RunPod 구성 (키, 데이터센터, Network Volume, GPU ID, 이미지, 모델)

**Files:**
- Create: `runpod/models.txt`, `runpod/seed-models.sh`
- Modify: `ec2/gpu-priority.txt` (PRO 6000 MIG ID 추가), `runpod-설계.md` 7장 표 기록

**Interfaces:**
- Produces: EC2 `.env`의 `RUNPOD_API_KEY`, `HF_TOKEN`, `NETWORK_VOLUME_ID`, `VLLM_IMAGE`, `MODEL_ID`

- [ ] **Step 1: 키 발급**

- RunPod 콘솔 → Settings → API Keys에서 키를 발급한다. EC2 `.env`의 `RUNPOD_API_KEY`에 넣는다.
- Billing에서 자동 충전을 켜고 잔액 알림을 설정한다.
- Hugging Face → Settings → Access Tokens에서 Read 토큰을 발급한다. `google/gemma-4-31B-it` 모델 페이지에서 라이선스 동의를 한 뒤 EC2 `.env`의 `HF_TOKEN`에 넣는다.

- [ ] **Step 2: 48GB Secure GPU ID 확인 → gpu-priority.txt 완성**

EC2에서 실행:
```bash
set -a; . /opt/voc-llm/.env; set +a
curl -s https://api.runpod.io/graphql -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' \
  -d '{"query":"query { gpuTypes { id displayName memoryInGb secureCloud } }"}' \
  | jq -r '.data.gpuTypes[] | select(.secureCloud and .memoryInGb >= 48 and .memoryInGb < 80) | "\(.id)\t\(.memoryInGb)GB\t\(.displayName)"'
```
Expected: 목록에 `NVIDIA RTX A6000`, `NVIDIA A40`, `NVIDIA L40`, `NVIDIA RTX 6000 Ada Generation`, `NVIDIA L40S`가 있다.

- 기존 5줄의 ID와 일치하지 않는 것이 있으면 출력된 `id`로 고친다.
- PRO 6000 MIG 48GB 항목이 있으면 그 `id`를 `ec2/gpu-priority.txt` 맨 아래에 추가한다.
- 목록에 없으면 추가하지 않고, `runpod-설계.md` 7장에 "MIG 48GB: API 목록에 없음(날짜)"이라고 기록한다.

- [ ] **Step 3: 데이터센터 선택과 Network Volume 생성**

1. RunPod 콘솔 → Storage → New Network Volume 화면에서 데이터센터별 GPU 목록을 본다. `NVIDIA RTX A6000`과 `NVIDIA A40`이 둘 다 있는 곳을 고르고, 그중 L40, RTX 6000 Ada, L40S가 가장 많은 곳을 선택한다.
2. 이름 `voc-llm-models`, 크기 100GB로 생성한다.
3. 생성된 Volume ID를 EC2 `.env`의 `NETWORK_VOLUME_ID`에 넣는다.
4. 데이터센터 ID와 제공 GPU 목록을 `runpod-설계.md` 7장 표에 기록한다.

- [ ] **Step 4: vLLM 이미지 태그 고정**

```bash
curl -s 'https://hub.docker.com/v2/repositories/vllm/vllm-openai/tags?page_size=50&ordering=last_updated' \
  | jq -r '.results[].name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -3
```
- 출력된 것 중 가장 높은 버전을 EC2 `.env`의 `VLLM_IMAGE=vllm/vllm-openai:<버전>`에 넣고 7장 표에 기록한다.
- 해당 버전의 릴리스 노트에서 CUDA 12.8 이상 빌드인지 확인한다. CUDA 12.8 미만이면 PRO 6000(Blackwell)에서 동작하지 않으므로 MIG 줄을 gpu-priority.txt에서 뺀다.

- [ ] **Step 5: 후보 모델 repo 확정 → runpod/models.txt**

```bash
for r in google/gemma-4-26B-A4B-it-qat-w4a16-ct google/gemma-4-31B-it-qat-w4a16-ct; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' https://huggingface.co/api/models/$r)" "$r"
done
for q in "Qwen3.6-35B-A3B AWQ" "Qwen3.8-27B AWQ" "gemma-4-26B-A4B w4a16"; do
  echo "== $q"
  curl -s "https://huggingface.co/api/models?search=$(echo "$q" | tr ' ' '+')&sort=downloads&limit=8" | jq -r '.[] | "\(.downloads)\t\(.id)"'
done
```
선택 기준:
- Gemma 공식 repo가 `200`이면 그 repo를 쓴다.
- 그 외에는 다운로드 수가 가장 많은 repo를 고른다. 단 작성자가 `Qwen`, `RedHatAI`, `cyankiwi`, `QuantTrio` 같은 검증된 양자화 작성자여야 하고, 모델 카드에 vLLM 실행 예시가 있어야 한다.

`runpod/models.txt` (확정한 4개 repo, 한 줄에 하나. 예시는 Gemma 2개 확정본):
```text
google/gemma-4-31B-it-qat-w4a16-ct
google/gemma-4-26B-A4B-it-qat-w4a16-ct
```
→ 위 검색 결과로 고른 Qwen3.6-35B-A3B AWQ repo와 Qwen3.8-27B AWQ repo를 2줄 추가한다. 4개 repo를 `runpod-설계.md` 5장, 7장 표에 기록한다.

- [ ] **Step 6: 모델 사전 다운로드 스크립트**

`runpod/seed-models.sh`:
```bash
#!/usr/bin/env bash
# EC2 에서 실행: bash runpod/seed-models.sh  → Network Volume 에 models.txt 의 모델을 받는 임시 Pod 생성
set -euo pipefail
set -a; . /opt/voc-llm/.env; set +a
MODELS=$(grep -v '^#' "$(dirname "$0")/models.txt" | grep -v '^$' | paste -sd' ' -)
GPUS=$(grep -v '^#' /opt/voc-llm/gpu-priority.txt | grep -v '^$' | jq -R . | jq -s .)
SPEC=$(jq -n --argjson gpus "$GPUS" --arg vol "$NETWORK_VOLUME_ID" --arg hf "$HF_TOKEN" --arg models "$MODELS" '{
  name: "voc-llm-seed", cloudType: "SECURE", gpuCount: 1,
  gpuTypeIds: $gpus, gpuTypePriority: "custom",
  imageName: "python:3.12-slim", containerDiskInGb: 20,
  networkVolumeId: $vol, volumeMountPath: "/workspace",
  env: { HF_TOKEN: $hf, HF_HOME: "/workspace/hf", MODELS: $models },
  dockerEntrypoint: ["bash", "-c"],
  dockerStartCmd: ["pip install -q -U huggingface_hub && for m in $MODELS; do hf download $m || echo SEED_FAIL $m; done; du -sh /workspace/hf/hub/*; echo SEED_DONE; sleep infinity"]
}')
curl -sS -X POST https://rest.runpod.io/v1/pods -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' -d "$SPEC" | jq '{id, costPerHr, machine}'
```

Run: `scp -r runpod ubuntu@<EIP>:~/ && ssh ubuntu@<EIP> 'bash ~/runpod/seed-models.sh'`

Expected:
- Pod `id`가 출력된다.
- RunPod 콘솔 → 해당 Pod → Logs에서 `SEED_DONE`이 나오고 `SEED_FAIL` 줄은 없어야 한다.
- 모델 4개의 크기 합계가 약 60~90GB로 보인다.

확인이 끝나면 seed Pod를 삭제한다:
```bash
curl -sS -X DELETE https://rest.runpod.io/v1/pods/<seed-pod-id> -H "Authorization: Bearer $RUNPOD_API_KEY" -w '%{http_code}\n'
```
Expected: `200` 또는 `204`

- [ ] **Step 7: 최초 모델 지정과 커밋**

EC2 `.env`에 `MODEL_ID=google/gemma-4-31B-it-qat-w4a16-ct`를 넣는다. Task 10에서 최종 선정한 모델로 바꾼다.
Qwen3.8-27B를 쓰는 경우에는 `VLLM_EXTRA_ARGS='--limit-mm-per-prompt {"image":0}'`도 넣는다.

로컬에서 바꾼 `gpu-priority.txt`를 EC2에 반영한다: `scp -r ec2 ubuntu@<EIP>:~/ && ssh ubuntu@<EIP> 'sudo bash ~/ec2/install.sh'`

```bash
git add ec2/gpu-priority.txt runpod runpod-설계.md
git commit -m "feat: RunPod GPU ID, Network Volume, 모델 사전 다운로드"
```

---

### Task 8: 통합 검증 (실제 RunPod, aws-설계.md 10장 1~6, 12~15)

**Files:**
- Modify (조건부): `ec2/bin/lib.sh`의 `do_start` 안 `gpu=`, `dc=`, `cost=` jq 경로
- Modify: `runpod-설계.md` 7장 (검증 결과 기록)

이 Task는 실제 RunPod에 과금된다. 대략 2~3시간에 $2~4 정도다. 항목 12~15는 평일 09:00~18:00에 실행해야 cron health가 동작한다. 그 외 시간에는 `sudo /opt/voc-llm/bin/pod-health.sh`를 2분 간격으로 수동 실행한다.

- [ ] **Step 0: 공휴일 API 실연동**

키는 발급과 동작 확인을 마쳤다(2026-11-13). 로컬 `ec2/.env`의 `HOLIDAY_API_KEY`에 들어 있고, Task 6 Step 5에서 `ec2/` 폴더를 복사할 때 EC2로 함께 넘어간다. 활용기간(보통 2년) 만료 전에 공공데이터포털 마이페이지에서 연장신청을 해야 한다.

```bash
sudo /opt/voc-llm/bin/holiday-sync.sh; tail -n1 /var/log/voc-llm/pod.log | jq .
head -5 /opt/voc-llm/holidays-api.txt; ls /opt/voc-llm/state/holiday_sync_failed 2>&1
```
Expected:
- `"result": "ok"`, `count`가 15 이상이다.
- `2026-01-01`처럼 형식이 맞는 날짜가 나온다.
- `holiday_sync_failed`는 `No such file`이다.

실패 동작 확인:
```bash
sudo sed -i 's/^HOLIDAY_API_KEY=.*/HOLIDAY_API_KEY=invalid/' /opt/voc-llm/.env
sudo HOLIDAY_RETRY_SEC=1 /opt/voc-llm/bin/holiday-sync.sh
```
Expected: `HOLIDAY_SYNC failed` 로그, 마커 파일 생성, SNS 메일 "Holiday sync failed"(Task 9 구독 확인 이후에만 온다).
확인이 끝나면 키를 원래대로 돌리고 다시 실행해서 마커가 지워지는지 본다.

- [ ] **Step 1: 수동 기동 (항목 1)**

```bash
sudo /opt/voc-llm/bin/pod-start.sh --force
tail -n1 /var/log/voc-llm/pod.log | jq .
```
Expected:
- `"result": "ok"`
- `gpu`와 `datacenter`가 `unknown`이 아니다.
- `cost_per_hr`가 0보다 크다.
- `stage` 1
- `ready_sec`가 1500 미만이다.

`gpu`, `datacenter`, `cost_per_hr` 중 하나라도 `unknown` 또는 0이면 실제 응답 구조를 확인한다:
```bash
set -a; . /opt/voc-llm/.env; set +a
curl -s https://rest.runpod.io/v1/pods/$(jq -r .pod_id /opt/voc-llm/state/current_pod) -H "Authorization: Bearer $RUNPOD_API_KEY" | jq .
```
출력에서 GPU ID, 데이터센터 ID, 시간당 비용이 들어 있는 키 경로를 찾는다. `ec2/bin/lib.sh` `do_start`의 `gpu=`, `dc=`, `cost=` 줄에서 jq 대체식(`//`) **맨 앞**에 그 경로를 추가한다. `tests/stub.sh`의 POST 응답도 같은 구조로 바꾼 뒤 `bash tests/run.sh`가 통과하는지 확인하고, EC2에 다시 설치한다.

Pod가 `failed_not_ready`로 끝나면 RunPod 콘솔 → Pod Logs에서 vLLM 오류를 확인한다. 예: `unrecognized arguments: --model`이 나오면 vLLM 이미지의 진입점이 다른 것이다. 이 경우 `pod_spec`의 `dockerStartCmd`에서 `"--model", $model` 두 원소를 `$model` 하나로 바꿔서 위치 인자로 넘기고, `t_pod_spec_stage1`의 기대 문자열을 같이 고친다.

- [ ] **Step 2: API 호출 (항목 5, 6, 관리자 PC)**

```bash
K=<고객사키>; D=<DOMAIN>
curl -s https://$D/v1/models -H "Authorization: Bearer $K" | jq -r '.data[].id'
curl -s https://$D/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"voc-llm","messages":[{"role":"user","content":"주차장 이용 시간 문의에 대한 답변 초안을 2문장으로 작성해줘."}],"max_tokens":200,"temperature":0}' | jq -r '.choices[0].message.content'
curl -sN https://$D/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"voc-llm","stream":true,"messages":[{"role":"user","content":"안녕하세요"}],"max_tokens":50}' | head -5
curl -s -o /dev/null -w '%{http_code}\n' https://$D/v1/models -H 'Authorization: Bearer wrong'
```
Expected:
- `voc-llm`
- 한국어 답변 2문장
- `data: {...}` 스트리밍 줄들
- `401`

고객사 IP나 관리자 IP가 아닌 곳(예: 휴대폰 핫스팟)에서 `curl https://$D/healthz`를 실행하면 연결 타임아웃이 나야 한다.

- [ ] **Step 3: 종료 (항목 4)**

```bash
sudo /opt/voc-llm/bin/pod-stop.sh --force
tail -n1 /var/log/voc-llm/pod.log | jq .
```
Expected:
- `"event": "STOP"`, `"result": "ok"`
- `est_cost_usd`가 `uptime_hr × cost_per_hr`와 같다.
- RunPod 콘솔에 Pod가 없다.
- `/v1/models` 호출이 503을 준다.

- [ ] **Step 4: GPU fallback (항목 2)**

```bash
sudo sed -i '0,/^NVIDIA RTX A6000$/s//NVIDIA NOT-A-GPU/' /opt/voc-llm/gpu-priority.txt
sudo /opt/voc-llm/bin/pod-start.sh --force && tail -n1 /var/log/voc-llm/pod.log | jq '{result, gpu, stage}'
sudo /opt/voc-llm/bin/pod-stop.sh --force
sudo install -m 644 ~/ec2/gpu-priority.txt /opt/voc-llm/
```
Expected: `result` ok, `gpu`는 `NVIDIA RTX A6000`이 아닌 다음 순위 GPU다. 다음 순위도 품절이면 그다음 순위가 나온다.

RunPod가 존재하지 않는 ID 때문에 요청 전체를 거부하면(`failed_no_gpu`), "custom 우선순위 목록에 없는 ID는 오류"라는 뜻이다. 그 경우에는 첫 줄을 그냥 삭제해서 같은 테스트를 하고, 결과를 `runpod-설계.md` 7장에 기록한다.

- [ ] **Step 5: 볼륨 없는 2단계 (항목 3)**

```bash
sudo cp /opt/voc-llm/.env /tmp/env.bak
sudo sed -i 's/^NETWORK_VOLUME_ID=.*/NETWORK_VOLUME_ID=invalid-volume-id/' /opt/voc-llm/.env
sudo CREATE_RETRIES=1 /opt/voc-llm/bin/pod-start.sh --force && tail -n1 /var/log/voc-llm/pod.log | jq '{result, stage, retries, ready_sec}'
sudo /opt/voc-llm/bin/pod-stop.sh --force
sudo cp /tmp/env.bak /opt/voc-llm/.env && sudo rm /tmp/env.bak
```
Expected: `result` ok, `stage` 2, `retries` 1이다. `ready_sec`는 1단계보다 길다(HF 다운로드 시간). 이 값을 `runpod-설계.md` 7장에 기록한다.

- [ ] **Step 6: 업무시간 감시와 복구 (항목 12~15, 평일 업무시간)**

```bash
sudo /opt/voc-llm/bin/pod-start.sh --force
```

12. RunPod 콘솔에서 해당 Pod를 Terminate한다. 2분 뒤 다음을 실행한다:
    `jq -r '.event+":"+.result' /var/log/voc-llm/pod.log | tail -4`
    Expected: `HEALTH:down`, `STOP:replaced`, `START:ok`가 나오고, 메일 2통(RunPod DOWN, RunPod recovered)이 온다.
13. RunPod 콘솔 → 현재 Pod → Connect → Web Terminal에서 `pkill -f "vllm"`을 실행한다. 약 6~8분 뒤 `HEALTH:degraded`, `HEALTH:down`, `STOP:replaced`, `START:ok`가 나온다.
    Web Terminal을 쓸 수 없는 이미지라면 `.env`의 `VLLM_API_KEY`를 임시로 다른 값으로 바꿔서 같은 결과(401로 실패)를 만든다. 확인 후 값을 원래대로 돌린다.
14. 복구 포기 확인:
    ```bash
    sudo sed -i 's#^MODEL_ID=.*#MODEL_ID=org/does-not-exist#' /opt/voc-llm/.env
    ```
    이후 Pod를 Terminate한다. 복구 3회(각 최대 25분)가 끝나면 `HEALTH:gave_up`과 메일 "RunPod recovery gave up"이 오고, 이후 Pod가 생성되지 않는다.
    오래 걸리므로 이 항목만 `sudo READY_TIMEOUT_SEC=120 /opt/voc-llm/bin/pod-health.sh`로 수동 실행해서 단축해도 된다.
    끝나면 `MODEL_ID`를 원래대로 돌리고 `sudo /opt/voc-llm/bin/pod-start.sh --force`를 실행한다.
15. 점검 모드 확인:
    ```bash
    sudo touch /opt/voc-llm/state/maintenance
    ```
    Pod를 Terminate하고 4분 기다린다. 로그에 HEALTH가 없어야 한다. 끝나면 `sudo rm /opt/voc-llm/state/maintenance`를 실행한다.
    다음 점검에서 `HEALTH:down`이 나오고 복구된다.

마지막에 `sudo /opt/voc-llm/bin/pod-stop.sh --force`를 실행한다.

- [ ] **Step 7: 결과 기록과 커밋**

`runpod-설계.md` 7장의 GPU별 검증 표에 실제로 확보한 GPU, `ready_sec`, 1단계/2단계 결과를 기록한다.

```bash
git add runpod-설계.md ec2/bin/lib.sh tests/stub.sh tests/test_lib.sh
git commit -m "test: RunPod 통합 검증 결과 기록"
```

---

### Task 9: 서버 모니터링 리소스와 알림 검증 (aws-설계.md 9장, 10장 7~11)

**Files:**
- Create: `infra/aws-monitoring.sh`

**Interfaces:**
- Consumes: `infra/aws.env`(`REGION`, `ALERT_EMAIL`, `DOMAIN`), `infra/aws.out`(`INSTANCE_ID`, `TOPIC_ARN`)
- Precondition: Task 6 설치 후 CloudWatch Agent가 지표를 보내고 있어야 한다. 설치 후 5분 이상 지난 시점에 실행한다.

- [ ] **Step 1: 모니터링 스크립트 작성**

`infra/aws-monitoring.sh`:
```bash
#!/usr/bin/env bash
# 관리자 PC 에서 실행. 재실행하면 알람/규칙을 같은 이름으로 덮어쓴다.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; . ./aws.out; set +a
export AWS_DEFAULT_REGION=$REGION
IID=$INSTANCE_ID
TOPIC=$TOPIC_ARN
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 1) SNS: 메일 구독, EventBridge 발행 허용
aws sns subscribe --topic-arn "$TOPIC" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
aws sns set-topic-attributes --topic-arn "$TOPIC" --attribute-name Policy --attribute-value "$(jq -nc --arg t "$TOPIC" --arg a "$ACCOUNT" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "owner", Effect: "Allow", Principal: {AWS: "*"}, Action: ["SNS:Publish","SNS:Subscribe","SNS:GetTopicAttributes","SNS:SetTopicAttributes"],
     Resource: $t, Condition: {StringEquals: {"AWS:SourceOwner": $a}}},
    {Sid: "events", Effect: "Allow", Principal: {Service: "events.amazonaws.com"}, Action: "sns:Publish", Resource: $t}
  ]}')"

# us-east-1 토픽 (Route 53 health check 알람 전용)
TOPIC_USE1=$(aws sns create-topic --region us-east-1 --name voc-llm-alerts --query TopicArn --output text)
aws sns subscribe --region us-east-1 --topic-arn "$TOPIC_USE1" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null

# 2) 자원 알람
EC2DIM="Name=InstanceId,Value=$IID"
alarm() {  # alarm NAME [put-metric-alarm 인자...]
  local name=$1; shift
  aws cloudwatch put-metric-alarm --alarm-name "voc-llm-$name" --alarm-actions "$TOPIC" --ok-actions "$TOPIC" "$@"
}
alarm cpu-high        --namespace AWS/EC2 --metric-name CPUUtilization   --dimensions "$EC2DIM" --statistic Average --period 300 --evaluation-periods 3 --threshold 80 --comparison-operator GreaterThanThreshold
alarm cpu-credit-low  --namespace AWS/EC2 --metric-name CPUCreditBalance --dimensions "$EC2DIM" --statistic Minimum --period 300 --evaluation-periods 1 --threshold 30 --comparison-operator LessThanThreshold
alarm mem-high        --namespace VOC-LLM --metric-name mem_used_percent  --dimensions "$EC2DIM" --statistic Average --period 60 --evaluation-periods 5 --threshold 85 --comparison-operator GreaterThanThreshold
alarm swap-high       --namespace VOC-LLM --metric-name swap_used_percent --dimensions "$EC2DIM" --statistic Average --period 60 --evaluation-periods 5 --threshold 50 --comparison-operator GreaterThanThreshold
# Agent 중단: mem 지표가 10분간 없으면 (값 자체는 0 미만이 될 수 없으므로 누락일 때만 발생)
alarm agent-missing   --namespace VOC-LLM --metric-name mem_used_percent  --dimensions "$EC2DIM" --statistic SampleCount --period 60 --evaluation-periods 10 --threshold 0 --comparison-operator LessThanThreshold --treat-missing-data breaching

DISK_DIMS=$(aws cloudwatch list-metrics --namespace VOC-LLM --metric-name disk_used_percent --dimensions "$EC2DIM" --query 'Metrics[0].Dimensions' --output json)
if [ "$DISK_DIMS" = null ]; then echo "disk_used_percent 지표가 아직 없습니다. Agent 설치 5분 뒤 다시 실행하세요." >&2; exit 1; fi
alarm disk-high --namespace VOC-LLM --metric-name disk_used_percent --dimensions "$DISK_DIMS" --statistic Maximum --period 300 --evaluation-periods 1 --threshold 80 --comparison-operator GreaterThanThreshold

# 3) 상태 점검 자동 복구 / 재부팅
aws cloudwatch put-metric-alarm --alarm-name voc-llm-status-system --namespace AWS/EC2 --metric-name StatusCheckFailed_System \
  --dimensions "$EC2DIM" --statistic Maximum --period 60 --evaluation-periods 2 --threshold 0 --comparison-operator GreaterThanThreshold \
  --alarm-actions "arn:aws:automate:$REGION:ec2:recover" "$TOPIC" --ok-actions "$TOPIC"
aws cloudwatch put-metric-alarm --alarm-name voc-llm-status-instance --namespace AWS/EC2 --metric-name StatusCheckFailed_Instance \
  --dimensions "$EC2DIM" --statistic Maximum --period 60 --evaluation-periods 3 --threshold 0 --comparison-operator GreaterThanThreshold \
  --alarm-actions "arn:aws:automate:$REGION:ec2:reboot" "$TOPIC" --ok-actions "$TOPIC"

# 4) 외부 생존 확인: Route 53 health check (리전 3곳으로 제한 → SG 규칙과 일치)
HC=$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='$DOMAIN' && HealthCheckConfig.ResourcePath=='/healthz'].Id | [0]" --output text)
if [ "$HC" = None ]; then
  HC=$(aws route53 create-health-check --caller-reference "voc-llm-$(date +%s)" --health-check-config \
    "Type=HTTPS,FullyQualifiedDomainName=$DOMAIN,Port=443,ResourcePath=/healthz,RequestInterval=30,FailureThreshold=3,Regions=us-east-1,ap-northeast-1,ap-southeast-1" \
    --query HealthCheck.Id --output text)
  aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$HC" --add-tags Key=Name,Value=voc-llm-healthz
fi
aws cloudwatch put-metric-alarm --region us-east-1 --alarm-name voc-llm-healthz-down --namespace AWS/Route53 --metric-name HealthCheckStatus \
  --dimensions "Name=HealthCheckId,Value=$HC" --statistic Minimum --period 60 --evaluation-periods 1 --threshold 1 \
  --comparison-operator LessThanThreshold --treat-missing-data breaching --alarm-actions "$TOPIC_USE1" --ok-actions "$TOPIC_USE1"

# 5) 인스턴스 중지/종료 이벤트
aws events put-rule --name voc-llm-ec2-state --event-pattern "$(jq -nc --arg i "$IID" '{
  source: ["aws.ec2"], "detail-type": ["EC2 Instance State-change Notification"],
  detail: {"instance-id": [$i], state: ["stopping","stopped","shutting-down","terminated"]}}')" >/dev/null
aws events put-targets --rule voc-llm-ec2-state --targets "Id=sns,Arn=$TOPIC" >/dev/null

# 6) 대시보드
aws cloudwatch put-dashboard --dashboard-name voc-llm --dashboard-body "$(jq -nc --arg r "$REGION" --arg i "$IID" --arg hc "$HC" --argjson dd "$DISK_DIMS" '
  def w(t; m): {type:"metric", width:8, height:6, properties:{title:t, region:$r, stat:"Average", period:300, metrics:[m]}};
  {widgets: [
    w("CPU %"; ["AWS/EC2","CPUUtilization","InstanceId",$i]),
    w("CPU credit"; ["AWS/EC2","CPUCreditBalance","InstanceId",$i]),
    w("Memory %"; ["VOC-LLM","mem_used_percent","InstanceId",$i]),
    w("Swap %"; ["VOC-LLM","swap_used_percent","InstanceId",$i]),
    w("Disk / %"; (["VOC-LLM","disk_used_percent"] + ($dd | map(.Name, .Value)))),
    {type:"metric", width:8, height:6, properties:{title:"healthz (1=up)", region:"us-east-1", stat:"Minimum", period:60,
      metrics:[["AWS/Route53","HealthCheckStatus","HealthCheckId",$hc]]}}
  ]}')" >/dev/null

echo "완료. $ALERT_EMAIL 로 온 구독 확인 메일 2통(서울, us-east-1)의 링크를 눌러야 알림이 옵니다."
```

- [ ] **Step 2: 실행과 구독 확인**

Run: `bash infra/aws-monitoring.sh`
Expected: `완료.` 메시지가 출력되고, 메일함에 "AWS Notification - Subscription Confirmation" 메일이 2통 온다. 두 메일의 링크를 모두 누른다.

Run: `aws cloudwatch describe-alarms --alarm-name-prefix voc-llm- --query 'MetricAlarms[].[AlarmName,StateValue]' --output table`
Expected: 알람 9개(cpu-high, cpu-credit-low, mem-high, swap-high, agent-missing, disk-high, status-system, status-instance + us-east-1의 healthz-down 1개는 `--region us-east-1`로 따로 조회)가 있다. 상태는 `OK` 또는 `INSUFFICIENT_DATA`이고 몇 분 뒤 `OK`가 된다.

- [ ] **Step 3: 알림 검증 (항목 7~11, EC2에서)**

7. `stress-ng --cpu 2 --timeout 20m`을 실행한다. 약 15~20분 뒤 `voc-llm-cpu-high` ALARM 메일이 오고, 종료 후 OK 메일이 온다.
8. 메모리와 디스크 알람을 확인한다:
   - `stress-ng --vm 1 --vm-bytes 1800M --timeout 8m`: 약 6분 뒤 mem-high 메일이 온다.
   - `fallocate -l 14G /tmp/fill`: 5~10분 뒤 disk-high 메일이 온다. 확인 후 `rm /tmp/fill`을 실행하고 OK 메일이 오는지 본다.
9. nginx 감시를 확인한다:
   - `sudo systemctl stop nginx`: 약 2~3분 뒤 healthz-down 메일이 온다. 이어서 `sudo systemctl start nginx`를 실행하면 OK 메일이 온다.
   - `sudo kill -9 $(cat /run/nginx.pid)`: 5초 뒤 `systemctl is-active nginx`가 `active`를 출력해야 한다.
10. EC2 콘솔에서 인스턴스를 중지한다. EventBridge 메일(state `stopping`, `stopped`)과 healthz-down 메일이 온다. 다시 시작하면 EIP가 그대로이고 `systemctl is-active nginx cron amazon-cloudwatch-agent`가 모두 `active`다.
11. `aws cloudwatch describe-alarms --alarm-names voc-llm-status-system voc-llm-status-instance --query 'MetricAlarms[].AlarmActions'`를 실행한다. `ec2:recover`와 `ec2:reboot` ARN이 각각 들어 있어야 한다.

- [ ] **Step 4: 커밋**

```bash
git add infra/aws-monitoring.sh
git commit -m "feat: CloudWatch 알람, Route 53 health check, EC2 상태 이벤트 알림"
```

---

### Task 10: 모델 선정 평가 (runpod-설계.md 5.1)

**Files:**
- Create: `eval/run_eval.py`, `eval/test_run_eval.py`
- Input (gitignore): `eval/samples.jsonl`. 고객사가 마스킹한 VOC 30~50건. 한 줄 형식: `{"id":"v001","task":"classify|summary|draft","messages":[{"role":"system","content":"..."},{"role":"user","content":"..."}]}`

**Interfaces:**
- `parse_sse_line(line: str) -> str | None`: `data: {...}` 줄에서 delta content를 반환한다. `[DONE]`이나 빈 줄이면 None을 반환한다.
- `python eval/run_eval.py run --label <모델별칭> --base https://<DOMAIN> --key <고객사키>`: 결과를 `eval/results/<label>.jsonl`에 기록한다. 한 줄 형식: `{id, task, output, ttft_sec, total_sec, completion_chars, chars_per_sec}`
- `python eval/run_eval.py blind eval/results/*.jsonl`: `eval/results/blind.csv`(id, task, A, B, C, D)와 `eval/results/blind_key.json`({"A": "<label>", ...})을 만든다

- [ ] **Step 1: 실패하는 테스트 작성**

`eval/test_run_eval.py`:
```python
import csv
import json
import tempfile
import unittest
from pathlib import Path

import run_eval


class ParseSse(unittest.TestCase):
    def test_content_delta(self):
        line = 'data: {"choices":[{"delta":{"content":"안녕"}}]}'
        self.assertEqual(run_eval.parse_sse_line(line), "안녕")

    def test_done_and_blank(self):
        self.assertIsNone(run_eval.parse_sse_line("data: [DONE]"))
        self.assertIsNone(run_eval.parse_sse_line(""))

    def test_role_only_and_usage_chunks(self):
        self.assertIsNone(run_eval.parse_sse_line('data: {"choices":[{"delta":{"role":"assistant"}}]}'))
        self.assertIsNone(run_eval.parse_sse_line('data: {"choices":[],"usage":{"completion_tokens":5}}'))


class Blind(unittest.TestCase):
    def test_blind_hides_labels_and_keeps_rows(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            for label, text in [("gemma31", "g"), ("qwen27", "q")]:
                (d / f"{label}.jsonl").write_text(
                    json.dumps({"id": "v1", "task": "draft", "output": text}, ensure_ascii=False) + "\n", encoding="utf-8")
            run_eval.blind(sorted(d.glob("*.jsonl")), d, seed=1)
            key = json.loads((d / "blind_key.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(key.values()), ["gemma31", "qwen27"])
            rows = list(csv.DictReader((d / "blind.csv").open(encoding="utf-8-sig")))
            self.assertEqual(len(rows), 1)
            self.assertEqual({rows[0][k] for k in key}, {"g", "q"})
            self.assertNotIn("gemma31", (d / "blind.csv").read_text(encoding="utf-8-sig"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd eval && py -3.12 -m unittest test_run_eval -v` (Linux에서는 `python3`)
Expected: `ModuleNotFoundError: No module named 'run_eval'`

- [ ] **Step 3: 구현**

`eval/run_eval.py`:
```python
"""VOC 샘플로 모델별 응답 품질/속도를 수집하고 블라인드 평가표를 만든다. stdlib 만 사용."""
import argparse
import csv
import json
import random
import string
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent


def parse_sse_line(line: str):
    line = line.strip()
    if not line.startswith("data:"):
        return None
    payload = line[5:].strip()
    if payload == "[DONE]":
        return None
    choices = json.loads(payload).get("choices") or []   # usage 전용 청크는 choices 가 비어 있다
    if not choices:
        return None
    return choices[0].get("delta", {}).get("content") or None


def call(base: str, key: str, messages: list, max_tokens: int):
    body = json.dumps({"model": "voc-llm", "messages": messages, "temperature": 0,
                       "max_tokens": max_tokens, "stream": True}).encode()
    req = urllib.request.Request(f"{base}/v1/chat/completions", data=body, method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    t0 = time.monotonic()
    ttft, parts = None, []
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            piece = parse_sse_line(raw.decode("utf-8", "replace"))
            if piece:
                if ttft is None:
                    ttft = time.monotonic() - t0
                parts.append(piece)
    total = time.monotonic() - t0
    text = "".join(parts)
    gen = total - (ttft or 0)
    return {"output": text, "ttft_sec": round(ttft or total, 3), "total_sec": round(total, 3),
            "completion_chars": len(text), "chars_per_sec": round(len(text) / gen, 1) if gen > 0 else 0}


def run(label: str, base: str, key: str, samples: Path, max_tokens: int):
    out_dir = HERE / "results"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / f"{label}.jsonl"
    with samples.open(encoding="utf-8") as f, out.open("w", encoding="utf-8") as w:
        for line in f:
            if not line.strip():
                continue
            s = json.loads(line)
            r = {"id": s["id"], "task": s.get("task", ""), **call(base, key, s["messages"], max_tokens)}
            w.write(json.dumps(r, ensure_ascii=False) + "\n")
            print(f'{r["id"]}\tttft={r["ttft_sec"]}s\ttotal={r["total_sec"]}s')
    print(f"saved {out}")


def blind(files, out_dir: Path, seed=None):
    files = list(files)
    labels = [Path(p).stem for p in files]
    rng = random.Random(seed)
    rng.shuffle(labels)
    letters = list(string.ascii_uppercase[:len(labels)])
    key = dict(zip(letters, labels))
    outputs = {}
    for p in files:
        for line in Path(p).read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                outputs.setdefault(r["id"], {"task": r.get("task", "")})[Path(p).stem] = r["output"]
    with (out_dir / "blind.csv").open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "task", *letters])
        for sid, row in outputs.items():
            w.writerow([sid, row["task"], *[row.get(key[l], "") for l in letters]])
    (out_dir / "blind_key.json").write_text(json.dumps(key, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--label", required=True)
    r.add_argument("--base", required=True, help="https://<DOMAIN>")
    r.add_argument("--key", required=True)
    r.add_argument("--samples", type=Path, default=HERE / "samples.jsonl")
    r.add_argument("--max-tokens", type=int, default=800)
    b = sub.add_parser("blind")
    b.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.cmd == "run":
        run(a.label, a.base.rstrip("/"), a.key, a.samples, a.max_tokens)
    else:
        blind(a.files, HERE / "results")
        print(f"saved {HERE / 'results' / 'blind.csv'} (평가자에게 blind_key.json 은 공유하지 않는다)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd eval && py -3.12 -m unittest test_run_eval -v`
Expected: 4개 `ok`

- [ ] **Step 5: 커밋**

```bash
git add eval/run_eval.py eval/test_run_eval.py
git commit -m "feat: 모델 평가 스크립트 (TTFT, 속도, 블라인드 CSV)"
```

- [ ] **Step 6: 4개 모델 평가 실행 (서비스 오픈 전, 같은 GPU에서)**

모델마다 아래를 반복한다. `<repo>`는 `runpod/models.txt`의 각 줄이고, `<label>`은 `gemma26`, `gemma31`, `qwen35`, `qwen27`이다.
```bash
# EC2
sudo sed -i "s#^MODEL_ID=.*#MODEL_ID=<repo>#" /opt/voc-llm/.env
sudo /opt/voc-llm/bin/pod-stop.sh --force; sudo /opt/voc-llm/bin/pod-start.sh --force
tail -n1 /var/log/voc-llm/pod.log | jq '{gpu, ready_sec}'     # GPU 가 RTX A6000 인지, 기동 시간 기록
# 관리자 PC
py -3.12 eval/run_eval.py run --label <label> --base https://<DOMAIN> --key <고객사키>
```
- 기동 GPU가 A6000이 아니면 그 회차는 비교에서 빼고 다시 실행한다. 속도 비교가 공정하려면 GPU가 같아야 한다.
- Qwen3.8-27B 회차에서만 `.env`에 `VLLM_EXTRA_ARGS='--limit-mm-per-prompt {"image":0}'`를 두고, 다른 모델 회차에서는 비운다.

4개가 끝나면:
```bash
py -3.12 eval/run_eval.py blind eval/results/gemma26.jsonl eval/results/gemma31.jsonl eval/results/qwen35.jsonl eval/results/qwen27.jsonl
```
`blind.csv`를 담당자에게 주고 A~D를 평가받는다. 평가자에게 `blind_key.json`은 주지 않는다.

- [ ] **Step 7: 최종 모델 반영**

1. 평가 점수, 평균 `ttft_sec`, 평균 `chars_per_sec`, `ready_sec`를 `runpod-설계.md` 5장 아래 "5.2 선정 결과" 표로 기록한다.
2. 1위 모델을 EC2 `.env`의 `MODEL_ID`에 넣는다.
3. `sudo /opt/voc-llm/bin/pod-stop.sh --force`를 실행한다. 다음 평일 08:30 cron부터 선정 모델로 운영된다.

```bash
git add runpod-설계.md
git commit -m "docs: 모델 선정 결과 기록"
```

---

## Spec Coverage (self-review)

| 스펙 항목 | Task |
|---|---|
| OpenAI 호환 API, 고객사 키, 내부 키 분리, SSE, 503 응답 (aws 3장) | 5, 6, 8 |
| cron 08:30 / 18:00 / 2분 health, 공휴일, 잠금 (aws 4장) | 2, 3, 4, 5 |
| pod-start 로직, 1·2단계, 재시도 3회, 25분 대기 (aws 5장) | 2, 8 |
| pod-stop 로직, 삭제 재시도, 추정 비용 (aws 6장) | 3, 8 |
| 업무시간 감시, 점검 A/B, 복구 3회, gave_up, 점검 모드 (aws 6-1장) | 4, 8 |
| 공휴일 API 주간 갱신, 수동 휴무일, 갱신 실패 주는 평일 전부 운영 (aws 6-2장) | 4-1, 5(cron, install), 8(Step 0) |
| START/STOP/HEALTH/HOLIDAY_SYNC 로그 형식과 result 값 (aws 7장) | 1~4, 4-1 |
| 수동 운영 절차 (aws 8장) | 2(`--force`), 3(`--force`), 4(maintenance) |
| CloudWatch 자원, Route 53, 상태 점검, EventBridge, 대시보드, 스왑, 로그 크기 제한 (aws 9장) | 5, 9 |
| 검증 1~15 (aws 10장) | 8(1~6, 12~15), 9(7~11) |
| Secure 전용, GPU 우선순위, MIG ID, CUDA 12.8 이상, 이미지 고정 (runpod 1, 3장) | 1, 7 |
| Network Volume 100GB, 데이터센터 선택, 사전 다운로드 (runpod 2장) | 7 |
| Pod 생성 사양, served-model-name, kv-cache auto, VLM 옵션 (runpod 4장) | 1, 7 |
| 모델 후보와 선정 방법 (runpod 5장) | 7, 10 |
| 보안: 포트 8000만 노출, 요청 본문 로그 없음, 볼륨에 VOC 데이터 없음 (runpod 6장) | 1(`ports`), 10(samples는 로컬에만 두고 gitignore) |
