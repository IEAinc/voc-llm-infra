# AWS 중계서버 설계

## 1. 리소스

| 리소스 | 사양 / 설정 |
|---|---|
| 리전 | ap-northeast-2 (서울) |
| EC2 | t3.small (2 vCPU / 2GB), Ubuntu 24.04 LTS |
| EBS | gp3 20GB |
| Elastic IP | 1개. 고객사 방화벽 화이트리스트와 DNS A 레코드에 사용한다 |
| 도메인 | 예: `llm-voc.<회사도메인>` A 레코드 → EIP |
| 인증서 | Let's Encrypt (certbot, 자동 갱신) |
| 시간대 | `timedatectl set-timezone Asia/Seoul` (cron이 KST 기준으로 동작해야 함) |

### Security Group

| 방향 | 포트 | 소스 | 용도 |
|---|---|---|---|
| Inbound | 443 | 고객사 VOC 서버 공인 IP | API |
| Inbound | 443 | Route 53 health checker IP 대역 | 외부 생존 확인 (9.3절). `ip-ranges.json`의 `ROUTE53_HEALTHCHECKS` 대역 사용 |
| Inbound | 80 | 0.0.0.0/0 | certbot 인증과 갱신 전용 (나머지는 443으로 리다이렉트) |
| Inbound | 22 | 관리자 IP | SSH |
| Outbound | 443 | 0.0.0.0/0 | RunPod API, RunPod proxy |

## 2. 디렉터리 구조

```
/opt/voc-llm/
├── .env                  # RUNPOD_API_KEY, VLLM_API_KEY, HF_TOKEN, MODEL_ID (권한 600)
├── gpu-priority.txt      # GPU 우선순위, 한 줄에 하나
├── holidays.txt          # 수동 휴무일(회사 자체 휴무 등) YYYY-MM-DD, 한 줄에 하나. 항상 적용
├── holidays-api.txt      # 공휴일 API 에서 받은 법정공휴일 (holiday-sync.sh 가 덮어씀, 6-2절)
├── pod-start.sh
├── pod-stop.sh
├── pod-health.sh         # 업무시간 RunPod 생존 감시 (6-1절)
├── holiday-sync.sh       # 매주 월요일 공휴일 API 갱신 (6-2절)
└── state/
    ├── holiday_sync_failed  # 마지막 공휴일 갱신 실패 표시. 있으면 API 공휴일을 적용하지 않음
    ├── current_pod       # 기동 중인 podId, 시작시각, 단가, GPU (stop 시 사용)
    ├── health_fail       # 연속 실패 횟수
    └── recover_YYYYMMDD  # 당일 자동 복구 횟수
/var/lock/voc-llm.lock    # start/stop/health 동시 실행 방지 (flock)
/etc/nginx/voc-llm/
├── upstream.conf         # cron이 덮어쓰는 파일 (ON/OFF 두 가지 내용)
└── client_keys.conf      # 고객사 API 키 목록
/var/log/voc-llm/pod.log  # 시작/종료 로그 (JSON Lines)
```

## 3. nginx

### 3.1 server 블록

```nginx
# /etc/nginx/conf.d/voc-llm.conf
map $http_authorization $client_ok {
    default 0;
    include /etc/nginx/voc-llm/client_keys.conf;   # "Bearer <고객사키>" 1;
}

server {
    listen 443 ssl http2;
    server_name llm-voc.example.com;
    ssl_certificate     /etc/letsencrypt/live/llm-voc.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/llm-voc.example.com/privkey.pem;

    client_max_body_size 2m;

    location /v1/ {
        if ($client_ok = 0) {
            return 401 '{"error":{"message":"invalid api key","type":"unauthorized"}}';
        }
        default_type application/json;

        include /etc/nginx/voc-llm/upstream.conf;

        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_buffering off;              # SSE 스트리밍
        proxy_read_timeout 300s;
        proxy_set_header Authorization "Bearer ${VLLM_API_KEY}";  # 설치 시 실제 키로 치환
    }

    # 외부 생존 확인용. 키 검증과 RunPod 상태에 영향을 받지 않는다 (9.3절)
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 'ok';
    }

    location / { return 404; }
}
```

- 고객사 키와 RunPod 내부 키(`VLLM_API_KEY`)를 분리한다. 고객사는 RunPod 주소나 내부 키를 알 수 없다.
- nginx 설정에는 환경변수 치환이 없다. 설치할 때 `envsubst '${VLLM_API_KEY}'`로 이 변수만 치환하고, 파일 권한은 600으로 둔다. 변수 목록을 지정하지 않으면 `$client_ok` 같은 nginx 변수까지 지워진다.

### 3.2 upstream.conf 두 가지 상태

ON (기동 완료 후 `pod-start.sh`가 기록):
```nginx
proxy_pass https://abc123xyz-8000.proxy.runpod.net;
proxy_set_header Host abc123xyz-8000.proxy.runpod.net;
```

OFF (종료 후, 또는 기동 전/실패 시 `pod-stop.sh`가 기록):
```nginx
return 503 '{"error":{"message":"LLM service is available weekdays 09:00-18:00 KST","type":"service_unavailable"}}';
```

파일을 교체한 뒤에는 `nginx -t && nginx -s reload`로 반영한다. reload는 처리 중인 요청을 끊지 않는다.

### 3.3 타임아웃 주의

RunPod HTTP proxy는 앞단 Cloudflare 때문에 **약 100초** 동안 응답이 없으면 연결을 끊는다.
긴 답변 생성은 `stream: true`로 호출하도록 고객사에 안내한다. 스트리밍은 토큰이 계속 흘러서 끊기지 않는다.

## 4. cron

```cron
# /etc/cron.d/voc-llm  (TZ=Asia/Seoul)
30 8 * * 1-5     root /opt/voc-llm/pod-start.sh
0 18 * * 1-5     root /opt/voc-llm/pod-stop.sh
30 19 * * 1-5    root /opt/voc-llm/pod-stop.sh   # 안전망: 18:00 stop 이 실패했을 때 재시도
*/2 9-17 * * 1-5 root /opt/voc-llm/pod-health.sh
0 7 * * 1        root /opt/voc-llm/holiday-sync.sh
```

- start·health 는 시작할 때 오늘이 휴일이면 종료한다. 휴일 판정 규칙은 6-2절을 따른다. start는 로그를 남기고 종료하고, health는 조용히 종료한다. stop 은 공휴일에도 항상 실행한다(남은 Pod 를 지워야 과금이 멈춘다).
- 세 스크립트는 같은 잠금 파일(`flock /var/lock/voc-llm.lock`)을 쓴다. 동시에 실행되지 않게 하기 위해서다.
  - start와 stop은 잠금을 얻을 때까지 기다린다.
  - health는 잠금을 얻지 못하면 바로 종료한다. 기동이나 복구가 진행 중이면 그 회차의 점검은 건너뛴다는 뜻이다.

## 5. pod-start.sh 로직

```
1. 오늘이 공휴일이면 START 로그(result=skipped_holiday)를 남기고 종료
2. state/current_pod 가 있으면 그 Pod 의 vLLM 을 확인한다. 준비됐으면 upstream ON 으로 다시 맞추고 START 로그(result=already_running) 후 종료. 준비 안 됐으면 삭제(do_stop) 후 새로 기동
3. Secure 데이터센터 어디서나 생성 (볼륨 없음, 모델은 기동 시 HF에서 다운로드)
   POST https://rest.runpod.io/v1/pods
     cloudType=SECURE, gpuTypeIds=gpu-priority.txt 순서, gpuTypePriority=custom,
     (runpod-설계.md 4장 사양)
   - 실패(자원 없음)면 10분 간격으로 최대 3회 재시도 (08:30 / 08:40 / 08:50)
4. 생성에 성공하면 GET /v1/pods/{id} 로 할당된 GPU, 데이터센터, costPerHr 조회
5. https://{id}-8000.proxy.runpod.net/v1/models 를 Authorization: Bearer $VLLM_API_KEY 로 호출해서
   200 을 줄 때까지 15초 간격으로 대기 (최대 15분)
6. 200 이면 upstream.conf ON 으로 교체 → reload → state/current_pod 기록 → START 로그(result=ok)
7. 5단계 타임아웃이면 Pod 삭제 → upstream OFF 유지 → START 로그(result=failed_not_ready)
8. 3단계 재시도가 모두 실패하면 START 로그(result=failed_no_gpu)
```

- `gpuTypePriority=custom`이면 RunPod가 목록 순서대로 자원을 찾는다. 따라서 호출 1번에 GPU fallback이 처리된다.
- REST API의 필드명과 GPU ID 문자열은 구축할 때 `GET /v1/gputypes`와 API 문서로 확인한 뒤 `gpu-priority.txt`에 기록한다. PRO 6000 MIG 48GB는 `gpuTypeIds` enum에 없어 제외했다.

## 6. pod-stop.sh 로직

```
1. state/current_pod 가 없으면 STOP 로그(result=no_pod) 후 upstream OFF 확인하고 종료
2. upstream.conf OFF 로 교체 → reload   (먼저 차단해서 삭제 중 요청 실패를 방지)
3. DELETE https://rest.runpod.io/v1/pods/{id}
4. 실패하면 30초 간격 3회 재시도. 그래도 실패하면 STOP 로그(result=failed_delete). Pod가 남아서 과금되므로 수동 확인 필요
5. 성공하면 가동시간, 추정비용 계산 → state/current_pod 삭제 → STOP 로그(result=ok)
```

## 6-1. pod-health.sh 로직 (업무시간 RunPod 생존 감시)

실행 주기는 평일 09:00~17:58, 2분 간격이다. 하는 일은 장애 감지, 알림, 자동 복구(Pod 교체) 세 가지다.

```
0. 잠금을 얻지 못하면 종료 (기동/복구 진행 중). state/maintenance 파일이 있으면 종료 (점검 작업 중)

1. state/current_pod 가 없으면 (아침 기동 실패, 또는 이전 복구 실패)
   → "Pod 없음"으로 판정하고 6번(복구)으로 이동

2. 점검 A: GET https://rest.runpod.io/v1/pods/{id}
   - 404, 또는 desiredStatus 가 RUNNING 이 아니면 (EXITED, TERMINATED 등)
     → 즉시 장애로 판정하고 5번으로 이동 (플랫폼이 Pod를 내린 것이 확실하므로 기다리지 않는다)
   - RunPod API 자체가 응답하지 않으면 점검 A는 판정하지 않고 점검 B 결과만 사용한다

3. 점검 B: GET https://{id}-8000.proxy.runpod.net/v1/models
   (Authorization: Bearer $VLLM_API_KEY, 타임아웃 20초)
   - 200 이면 정상. health_fail 을 0으로 초기화하고 종료
     (직전 점검이 실패였다면 HEALTH 로그(result=recovered_self)를 남긴다. 장애 확정 전이므로 알림은 보내지 않는다)
   - 그 외(타임아웃, 5xx, 연결 실패)면 health_fail += 1

4. health_fail 이 3 미만이면 종료
   - 일시적 지연(부하, 프록시 순간 오류)으로 오탐하지 않기 위해 약 6분 연속 실패해야 장애로 본다
   - 1회째 실패에만 HEALTH 로그(result=degraded)를 남긴다

5. 장애 확정
   → HEALTH 로그(result=down) + SNS 알림 "RunPod 장애 감지: podId, GPU, 원인(점검 A 또는 B)"

6. 자동 복구 (당일 복구 횟수 recover_YYYYMMDD < 3 일 때만)
   a. upstream.conf OFF → reload   (복구 중에는 고객사에 503 응답)
   b. pod-stop.sh 의 삭제 절차 실행 → STOP 로그(result=replaced)
      (장애 Pod도 과금되므로 반드시 먼저 삭제한다)
   c. pod-start.sh 의 생성 절차 실행 (GPU 우선순위, 재시도 동일) → START 로그
   d. recover_YYYYMMDD += 1, health_fail = 0
   e. SNS 알림 "자동 복구 완료: 새 podId, GPU, 소요시간" 또는 "자동 복구 실패"
   - 당일 복구 횟수가 3회에 도달하면 더 이상 Pod를 교체하지 않는다.
     HEALTH 로그(result=gave_up)와 SNS 알림 "수동 조치 필요"를 남긴다.
     같은 원인으로 Pod를 계속 만들고 지우는 반복과 과금을 막기 위해서다.
```

- 감지 시간: 응답 장애는 최대 약 6분, Pod 강제 종료는 최대 약 2분이다.
- 복구 시간: 모델을 HF에서 받으므로 기동에 약 4분(실측), HF가 느리면 최대 15분까지 걸릴 수 있다.
- 17:30 이후에 장애가 나면 복구가 18:00 종료와 겹친다. 이때 pod-stop.sh는 잠금을 기다렸다가 새 Pod를 삭제한다. 30분 미만 사용을 위해 Pod를 다시 만드는 비용은 감수한다.
- `pod-start.sh`의 실패 결과(`failed_no_gpu`, `failed_not_ready`)도 같은 SNS 토픽으로 알린다. 아침 기동에 실패한 경우 09:00부터 health가 1번 분기로 재시도한다.

## 6-2. holiday-sync.sh 로직 (공휴일 자동 갱신)

목적: 법정공휴일, 대체공휴일, 임시공휴일을 사람이 입력하지 않아도 반영한다.

| 항목 | 값 |
|---|---|
| 데이터 | 공공데이터포털 "한국천문연구원 특일 정보" `getRestDeInfo` (공휴일 정보) |
| 키 | `.env`의 `HOLIDAY_API_KEY` (공공데이터포털 일반 인증키, Decoding 값) |
| 주기 | 매주 월요일 07:00. 08:30 Pod 기동보다 먼저 끝나도록 한다. 설치할 때도 1회 실행한다 |
| 대상 | 올해와 내년. 내년 자료가 아직 없으면 올해만 반영한다 |

```
1. 올해 공휴일 조회. 실패하면 10분 간격으로 최대 3회 시도 (07:00 / 07:10 / 07:20)
   성공 조건: HTTP 200, resultCode "00", isHoliday=Y 항목 10개 이상
   (키 오류일 때 XML 로 오는 응답, 빈 응답, 비정상적으로 적은 개수는 모두 실패로 본다)
2. 3회 모두 실패
   → state/holiday_sync_failed 생성
   → HOLIDAY_SYNC 로그(result=failed) + SNS 알림
   → 기존 holidays-api.txt 는 그대로 두되 사용하지 않는다
3. 성공
   → 내년 조회 (실패해도 무시)
   → holidays-api.txt 를 올해 + 내년 날짜로 교체
   → state/holiday_sync_failed 삭제
   → HOLIDAY_SYNC 로그(result=ok, count)
```

휴일 판정 규칙 (`is_holiday`):

| 조건 | 판정 |
|---|---|
| 오늘이 `holidays.txt`(수동 휴무일)에 있음 | 휴일 (API 성공 여부와 무관하게 항상 적용) |
| `holiday_sync_failed`가 있음 | **휴일 아님**. 갱신에 실패한 주는 평일(월~금)에 모두 운영한다 |
| 오늘이 `holidays-api.txt`에 있음 | 휴일 |
| 그 외 | 평일 |

- 갱신에 실패하면 다음 갱신이 성공할 때까지(보통 다음 주 월요일) 공휴일에도 Pod가 뜬다. 하루 최대 약 $12의 비용이 생기는 대신, 잘못된 자료로 평일에 서비스를 멈추는 일은 생기지 않는다.
- 키 문제를 고친 뒤 `sudo /opt/voc-llm/bin/holiday-sync.sh`를 수동 실행하면 바로 정상 판정으로 돌아온다.

## 7. 로그 형식

파일: `/var/log/voc-llm/pod.log`. 한 줄이 JSON 객체 하나다(JSON Lines). logrotate로 월 단위 보관하고 12개월치를 유지한다.

START (시작 시):
```json
{"event":"START","ts":"2026-11-16T08:34:52+09:00","result":"ok",
 "requested_at":"2026-11-16T08:30:00+09:00","ready_at":"2026-11-16T08:34:52+09:00","ready_sec":292,
 "pod_id":"abc123xyz","gpu":"NVIDIA A40","datacenter":"EU-SE-1","retries":0,
 "cost_per_hr":0.59,"model":"Qwen/Qwen3.6-35B-A3B-AWQ","endpoint":"https://abc123xyz-8000.proxy.runpod.net"}
```

STOP (종료 시):
```json
{"event":"STOP","ts":"2026-11-16T18:00:41+09:00","result":"ok",
 "pod_id":"abc123xyz","gpu":"NVIDIA A40","started_at":"2026-11-16T08:30:12+09:00",
 "uptime_hr":9.51,"cost_per_hr":0.59,"est_cost_usd":5.61}
```

| result 값 | 의미 |
|---|---|
| `ok` | 정상 |
| `skipped_holiday` (START) | 공휴일이라 건너뜀 |
| `already_running` | 이미 기동 중인 Pod가 있음 |
| `failed_no_gpu` | 재시도 모두 GPU 확보 실패 |
| `failed_not_ready` | Pod는 생성됐지만 15분 안에 vLLM이 준비되지 않음 (Pod 삭제함) |
| `failed_reload` | vLLM은 준비됐지만 nginx reload 실패 (Pod 삭제함) |
| `failed_aborted` (START) | Pod 생성 후 예기치 않게 중단됨 (Pod 삭제 시도, 알림 발송) |
| `no_pod` | 종료 시점에 기동 중인 Pod가 없음 |
| `failed_delete` | Pod 삭제 실패. 수동 조치 필요 |
| `replaced` (STOP) | 장애 Pod를 자동 복구하려고 삭제함 |

HEALTH (업무시간 감시, 상태가 바뀔 때만 기록. 정상 점검은 기록하지 않는다):
```json
{"event":"HEALTH","ts":"2026-11-16T13:24:00+09:00","result":"down",
 "pod_id":"abc123xyz","gpu":"NVIDIA A40","check":"B","detail":"timeout 20s","fail_count":3,
 "recover_count_today":0}
```

| result 값 (HEALTH) | 의미 |
|---|---|
| `degraded` | 첫 점검 실패 (아직 장애 확정 아님) |
| `down` | 장애 확정 (SNS 알림) |
| `recovered_self` | 복구 조치 전에 스스로 정상으로 돌아옴 |
| `no_pod` | 업무시간인데 기동된 Pod가 없음 (복구 시도) |
| `gave_up` | 당일 자동 복구 3회 초과. 수동 조치 필요 |

HOLIDAY_SYNC (공휴일 갱신, 매주 1줄):
```json
{"event":"HOLIDAY_SYNC","ts":"2026-11-16T07:00:02+09:00","result":"ok","year":2026,"count":34,"next_year_count":18}
```
`result`는 `ok` 또는 `failed`다. `failed`면 `attempts` 필드가 들어간다.

자동 복구가 일어나면 로그에 `HEALTH(down)` → `STOP(replaced)` → `START(ok)` 순서로 남는다. 따라서 하루에 시작/종료 로그가 여러 쌍일 수 있고, 비용 합산 방식은 그대로 쓸 수 있다.

월별 비용 확인: `jq -s '[.[]|select(.event=="STOP")|.est_cost_usd]|add' pod.log`

## 8. 수동 운영 절차

| 상황 | 조치 |
|---|---|
| 업무시간 중 Pod 장애 | `pod-health.sh`가 자동으로 복구한다. `gave_up` 알림을 받으면 원인(RunPod 상태 페이지, 모델 로딩 오류 등)을 확인한 뒤 `pod-stop.sh`, `pod-start.sh` 순서로 수동 실행한다 |
| 감시를 잠시 끄고 작업 | `touch /opt/voc-llm/state/maintenance`. 이 파일이 있으면 health는 바로 종료한다. 작업이 끝나면 파일을 삭제한다 |
| 휴일인데 기동해야 함 | `pod-start.sh --force` 실행 (`--force`면 공휴일 체크를 건너뛴다) |
| 모델 교체 | `.env`의 `MODEL_ID` 변경. 다음 기동부터 반영된다. 고객사 쪽 `model` 값은 `voc-llm` 그대로 |
| 고객사 키 교체 | `client_keys.conf`를 수정한 뒤 reload |
| 회사 자체 휴무일 | 저장소의 `ec2/holidays.txt`에 날짜를 추가하고 `install.sh`를 다시 실행한다. 저장소 파일이 원본이라 install 이 서버의 `holidays.txt`를 덮어쓰므로 서버에서 직접 고치면 사라진다 (법정공휴일은 자동 반영되므로 넣지 않아도 된다) |
| 공휴일 갱신 실패 알림 | `.env`의 `HOLIDAY_API_KEY`가 공공데이터포털의 "Decoding"(일반) 인증키인지, 유효한지 확인한 뒤 `holiday-sync.sh`를 수동 실행 |

## 9. 서버 자원 및 생존 모니터링

목적: 디스크, 메모리, CPU가 부족해지는 상황과 서버가 꺼진 상황을 감지해서 담당자에게 알린다.
가능한 경우 자동으로 복구한다.

### 9.1 알림 채널

- SNS 토픽 `voc-llm-alerts`를 만들고, 담당자 이메일을 구독(subscription)으로 등록한다.
  슬랙이 필요하면 같은 토픽에 AWS Chatbot을 연결한다.
- 9.3절의 Route 53 health check 지표는 **us-east-1에만** 생긴다.
  그러므로 us-east-1에도 같은 이름의 SNS 토픽을 만들어 같은 이메일을 구독한다.
- 알람은 상태가 ALARM으로 바뀔 때와 OK로 돌아올 때 모두 알림을 보낸다. 복구도 알 수 있도록 하기 위해서다.

### 9.2 자원 지표 (CloudWatch)

CPU는 EC2 기본 지표로 수집된다. 메모리와 디스크는 기본 지표가 없으므로 **CloudWatch Agent**를 설치해서 60초 간격으로 수집한다.
EC2에는 `CloudWatchAgentServerPolicy`가 붙은 IAM 역할을 연결한다.

```json
// /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "metrics": {
    "namespace": "VOC-LLM",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"], "metrics_collection_interval": 60 },
      "swap": { "measurement": ["swap_used_percent"], "metrics_collection_interval": 60 },
      "disk": { "measurement": ["used_percent"], "resources": ["/"], "metrics_collection_interval": 60 }
    }
  }
}
```

| 알람 | 지표 | 조건 | 조치 |
|---|---|---|---|
| CPU 과부하 | `AWS/EC2 CPUUtilization` | 80% 초과가 5분 × 3회 연속 | 알림 |
| CPU 크레딧 고갈 | `AWS/EC2 CPUCreditBalance` | 30 미만 | 알림 (t3는 크레딧이 떨어지면 성능이 기준치 20%로 제한되거나 unlimited 추가 과금이 생긴다) |
| 메모리 부족 | `VOC-LLM mem_used_percent` | 85% 초과가 5분 연속 | 알림 |
| 스왑 사용 | `VOC-LLM swap_used_percent` | 50% 초과가 5분 연속 | 알림 |
| 디스크 부족 | `VOC-LLM disk_used_percent (/)` | 80% 초과 | 알림 |

추가 설정:
- **스왑 1GB 생성**: RAM이 2GB라서 순간적으로 메모리가 몰리면 OOM으로 nginx가 죽을 수 있다. 이를 완충하는 용도다.
- **디스크 증가 방지**: `pod.log`, nginx 로그, journald 크기를 logrotate와 `SystemMaxUse=200M`으로 제한한다.

### 9.3 서버 켜짐/꺼짐 감지

서버 내부의 에이전트는 서버가 꺼지면 알릴 수 없다. 그래서 **외부에서 확인하는 방식**을 같이 쓴다.

| 감지 대상 | 방법 | 조건 | 조치 |
|---|---|---|---|
| 서비스 응답 (서버 다운, nginx 다운, 네트워크 단절 모두 포함) | Route 53 HTTPS health check → `https://<도메인>/healthz` (30초 간격) | 연속 3회 실패 | 알림 (us-east-1 알람) |
| 하드웨어/호스트 장애 | `StatusCheckFailed_System` | 2분 연속 실패 | **EC2 recover** 액션으로 다른 호스트에서 자동 복구 (EIP와 디스크 유지) + 알림 |
| OS 행(hang) | `StatusCheckFailed_Instance` | 3분 연속 실패 | **EC2 reboot** 액션 + 알림 |
| 인스턴스 중지/종료 | EventBridge 규칙: `EC2 Instance State-change Notification`, state = `stopping`, `stopped`, `shutting-down`, `terminated` | 발생 즉시 | 알림 (사람이 실수로 끈 경우도 감지) |
| CloudWatch Agent 중단 | `mem_used_percent` 알람의 missing data를 breaching으로 처리 | 지표 10분 누락 | 알림 |

서버 내부 자가 복구:
- nginx systemd 유닛에 `Restart=on-failure`, `RestartSec=5`를 override로 추가한다. nginx 프로세스가 죽으면 즉시 재시작된다.
- 재부팅되면 nginx, cron, CloudWatch Agent가 자동 시작되도록 `systemctl enable`로 설정한다.
- 업무시간 중에 재부팅되면 `state/current_pod`와 `upstream.conf`가 디스크에 남아 있으므로 RunPod 연결이 그대로 복원된다.

### 9.4 대시보드

CloudWatch 대시보드 `voc-llm` 하나에 아래 6개 위젯을 둔다.
- CPU
- CPU 크레딧
- 메모리
- 스왑
- 디스크
- health check 상태

### 9.5 모니터링 비용 (월)

| 항목 | 금액 |
|---|---|
| CloudWatch Agent 사용자 지표 3개 × $0.30 | $0.90 |
| 알람 약 9개 × $0.10 | $0.90 |
| Route 53 HTTPS health check (AWS 엔드포인트 $0.50 + HTTPS $1.00) | $1.50 |
| EventBridge, SNS 이메일 | 무료 수준 |
| **합계** | **약 $3.3** |

## 10. 검증 항목

1. `pod-start.sh` 수동 실행: START 로그가 남고, `/v1/models`가 200을 주는지 확인한다.
2. `gpu-priority.txt`의 1순위를 없는 ID로 바꾸고 실행: 2순위 GPU로 기동되는지, 로그의 `gpu` 값이 맞는지 확인한다.
3. 모델 다운로드 포함 `ready_sec`가 15분 제한 안에 들어오는지(실측 약 4분) 확인한다.
4. `pod-stop.sh` 실행: STOP 로그가 남고 RunPod 콘솔에서 Pod가 사라졌는지 확인한다. API 호출 결과가 503인지 확인한다.
5. 잘못된 키로 호출했을 때 401, 허용되지 않은 IP에서 호출했을 때 연결이 거부되는지 확인한다.
6. `stream: true`와 `stream: false` 요청이 모두 정상 응답하는지 확인한다.
7. `stress-ng --cpu 2 --timeout 20m`을 실행해서 CPU 알람 메일이 오고, 종료 후 OK 메일이 오는지 확인한다.
8. `stress-ng --vm 1 --vm-bytes 1800M`을 실행해서 메모리 알람을 확인한다. `fallocate -l 14G /tmp/fill`로 디스크 알람을 확인하고, 확인 후 파일을 삭제한다.
9. `systemctl stop nginx`를 실행해서 Route 53 health check 실패 알림을 확인한다. `kill -9 <nginx master pid>`를 실행해서 systemd가 자동 재시작하는지 확인한다.
10. 콘솔에서 인스턴스를 중지해서 EventBridge 중지 알림이 오는지 확인한다. 재기동한 뒤 nginx와 Agent가 자동 시작되는지 확인한다.
11. `StatusCheckFailed`는 강제로 재현할 수 없다. 알람에 recover와 reboot 액션이 연결되어 있는지 콘솔에서 확인하는 것으로 대신한다.
12. 업무시간에 RunPod 콘솔에서 Pod를 강제로 Terminate한다. 2분 안에 `HEALTH(down)`, `STOP(replaced)`, `START(ok)` 로그와 SNS 알림 2건(장애, 복구 완료)이 오는지 확인한다.
13. Pod 안에서 vLLM 프로세스만 종료한다(Pod는 RUNNING 유지). 약 6분 뒤 점검 B로 장애가 확정되고 복구되는지 확인한다.
14. 복구가 계속 실패하도록 `MODEL_ID`를 없는 값으로 바꾼다. 3회 시도 후 `gave_up` 알림이 오고 더 이상 Pod가 생성되지 않는지 확인한다.
15. `state/maintenance`를 만든 뒤 Pod를 내려서 감시가 동작하지 않는지 확인한다.
