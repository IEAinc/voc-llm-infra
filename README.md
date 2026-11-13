# VOC LLM 인프라 설계 (AWS 중계 + RunPod 추론)

작성일: 2026-11-13

## 1. 목적

한국체육산업개발 VOC 시스템이 고정된 API 주소 하나로 LLM을 호출하도록 한다.
GPU 서버(RunPod)는 평일 업무시간에만 기동해 비용을 줄이고, GPU 종류나 Pod가 바뀌어도 고객사 쪽은 아무것도 바꾸지 않게 한다.

## 2. 전체 구성

```
VOC 시스템 ──HTTPS(고정 도메인)──▶ AWS EC2 t3.small (서울)
                                     │  nginx
                                     │   ├─ 고객사 API 키 검증 (불일치 401)
                                     │   ├─ Pod 미기동/운영시간 외 → 503 JSON
                                     │   └─ /v1/* → RunPod 프록시 (내부 키로 교체)
                                     │  cron
                                     │   ├─ 평일 08:30 pod-start.sh  (생성 + 대기 + upstream 갱신 + 로그)
                                     │   └─ 평일 18:00 pod-stop.sh   (삭제 + upstream 503 + 로그)
                                     ▼
                       RunPod Secure Cloud Pod (48GB GPU)
                         vLLM OpenAI 호환 서버 :8000
                         https://{podId}-8000.proxy.runpod.net
                         기동 시 HuggingFace 에서 모델 다운로드(볼륨 없음)
```

## 3. 확정된 결정

| 항목 | 결정 |
|---|---|
| API 형식 | OpenAI 호환 (`/v1/chat/completions`, `/v1/models`) |
| 개인정보 | 고객사 VOC 시스템이 마스킹한 뒤 전송한다. 중계서버는 내용을 변환하지 않는다 |
| GPU 등급 | RunPod Secure Cloud만 사용한다 (Community, Vast.ai는 기능 테스트 용도로만 사용) |
| 모델 보관 | Network Volume 없음(3안): 기동 시 HuggingFace에서 다운로드, 실측 약 4분 |
| Pod 수명 | 매일 생성(08:30)하고 매일 삭제(18:00)한다. stop/start 재사용은 하지 않는다 |
| GPU 우선순위 | 비용 순: A40 → RTX A6000 → L40 → RTX PRO 5000 Blackwell → L40S → RTX 6000 Ada (PRO 6000 MIG 48GB는 REST API `gpuTypeIds`에 없어 제외) |
| 로그 | 시작 시와 종료 시에 각 1줄씩 JSON으로 기록한다 (`/var/log/voc-llm/pod.log`) |
| 추론 엔진 | vLLM 단일 엔진. 4개 후보 모델을 같은 조건에서 비교한다 |
| 모델 이름 | `--served-model-name voc-llm`으로 고정한다. 모델을 교체해도 고객사 요청의 `model` 값은 그대로다 |
| EC2 모니터링 | CloudWatch(CPU, 메모리, 디스크, 스왑)와 Route 53 외부 health check, EC2 상태 점검, 중지 이벤트를 감지해서 SNS 이메일로 알린다. 하드웨어 장애는 자동 recover, OS 행은 자동 reboot한다 |
| 휴일 | 주말에는 cron이 실행되지 않는다. 법정공휴일은 공공데이터포털 API로 매주 월요일에 자동 갱신하고, 회사 휴무일은 `holidays.txt`에 직접 적는다. API 갱신에 실패한 주는 공휴일 판정을 끄고 평일에 모두 운영한다 |
| RunPod 감시 | 업무시간에 2분 간격으로 점검한다. Pod가 종료되면 즉시, 응답이 6분 연속 없으면 장애로 판정한다. 장애 Pod를 삭제하고 새로 만들어 자동 복구하며, 하루 최대 3회까지 시도한다. 장애 판정, 복구 완료, 복구 포기 시 SNS로 알린다 |

## 4. 비용 (월 기준)

| 항목 | 산식 | 금액 |
|---|---|---|
| EC2 t3.small (서울) | $0.026 × 730h | 약 $19.0 |
| EC2 공인 IPv4 (EIP) | $0.005 × 730h | 약 $3.7 |
| EBS gp3 20GB | 약 $0.0912/GB | 약 $1.8 |
| RunPod GPU (1순위 A40) | $0.59 × 약 200h (평일 21일 × 9.5h) | 약 $118 |
| EC2 모니터링 (CloudWatch, Route 53 health check) | aws-설계.md 9.5절 | 약 $3.3 |
| **합계** | | **약 $146** |

- RunPod 시간은 08:30~18:00, 9.5시간으로 계산했다. 기동 대기 30분이 포함되어 있다.
- 대체 GPU로 기동한 날은 그날 단가로 과금된다. 1순위 A40 $0.59, 최악은 RTX 6000 Ada·L40S $1.09/h이다(`gpu-priority.txt` 기준). 실제 비용은 종료 로그의 `est_cost_usd`를 합산해서 확인한다.
- 네트워크 송신 비용은 텍스트 응답 위주라 미미하므로 제외했다.

## 5. 문서 구성

- [aws-설계.md](aws-설계.md): EC2, nginx, cron 스크립트, 로그 형식, 운영 절차, 자원 및 생존 모니터링
- [runpod-설계.md](runpod-설계.md): 모델 로딩, Pod 생성 사양, vLLM 설정, 모델 후보, GPU 호환성

## 6. 범위 외 (1차)

- vLLM 품질 저하 감지(응답은 오지만 내용이 이상한 경우): 생존 감시는 `/v1/models` 응답 여부만 본다.
- 고객사 사용량 집계와 과금: 필요해지면 nginx access log로 집계한다.
