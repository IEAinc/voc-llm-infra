# RunPod LLM 서버 설계

## 1. 계정과 키

| 항목 | 설정 |
|---|---|
| 클라우드 | **Secure Cloud만** 사용한다 (Community는 테스트에서도 VOC 데이터를 넣지 않는다) |
| RunPod API 키 | 권한을 최소로 둔 키 1개 발급. AWS `/opt/voc-llm/.env`에만 보관한다 |
| HF 토큰 | read 권한. Gemma 계열 라이선스 동의 계정으로 발급한다 |
| vLLM 내부 키 | 무작위 32바이트 이상 (`VLLM_API_KEY`). AWS nginx만 알고 있다 |
| 결제 | 잔액 부족으로 Pod 생성이 실패하지 않도록 자동 충전을 켜고 최소 잔액 알림을 설정한다 |

## 2. 모델 로딩

Network Volume은 쓰지 않는다(3안). Pod는 매일 새로 만들고, 기동할 때마다 vLLM이 모델을 Hugging Face에서 컨테이너 디스크(`HF_HOME=/root/.cache/huggingface`, 40GB)로 받는다.
볼륨이 없으므로 RunPod가 재고가 있는 아무 Secure 데이터센터에 Pod를 띄운다.

실측 (2026-11-13, A40, EU-SE-1 / CA-MTL-1, `google/gemma-4-31B-it-qat-w4a16-ct`, `vllm/vllm-openai:v0.33.0`):
- Pod RUNNING까지 약 5초
- vLLM `/v1/models` 200까지 3분 21초 ~ 3분 48초 (다운로드와 로딩 포함)
- 첫 completion 4~5초

위험과 대응:
- HF 장애나 속도 저하가 있으면 기동이 늦어진다. `READY_TIMEOUT_SEC`를 15분으로 두고(실측 약 4분의 3배 이상), 초과하면 Pod를 삭제하고 실패 알림을 보낸다.
- 후보 모델 repo 목록은 `runpod/models.txt`에 둔다.

## 3. GPU 우선순위와 호환성

| 순위 | GPU | 아키텍처 (SM) | 단가 | 비고 |
|---|---|---|---|---|
| 1 | A40 48GB | Ampere (8.6) | $0.59 | 기준 GPU |
| 2 | RTX A6000 48GB | Ampere (8.6) | $0.69 | A40과 사실상 같은 성능 |
| 3 | L40 48GB | Ada (8.9) | $0.82 | |
| 4 | RTX PRO 5000 Blackwell | Blackwell (12.0) | $0.96 | |
| 5 | L40S 48GB | Ada (8.9) | $1.09 | |
| 6 | RTX 6000 Ada 48GB | Ada (8.9) | $1.09 | |

RTX PRO 6000 MIG 48GB는 REST API `gpuTypeIds` enum에 없어 생성할 수 없으므로 제외했다.

호환성 원칙:
- **CUDA 12.8 이상 vLLM 이미지**를 쓴다. 이 이미지는 Ampere부터 Blackwell까지 6종 모두를 지원한다. 이미지 태그는 버전을 고정한다(예: `vllm/vllm-openai:v0.x.y`, 확정: `v0.33.0`). `latest`는 쓰지 않는다.
- 양자화는 **W4A16 계열**(AWQ, compressed-tensors w4a16)로 통일한다. 6종 모두 Marlin 커널로 동작한다.
- FP8 가중치나 FP8 KV cache는 쓰지 않는다. Ampere에는 FP8 하드웨어가 없어서 GPU에 따라 결과와 속도가 달라진다. `--kv-cache-dtype auto`로 고정한다.
- 신규 GPU가 우선순위에 추가되면 7장 체크리스트로 검증한 뒤에 `gpu-priority.txt`에 넣는다.

## 4. Pod 생성 사양

AWS `pod-start.sh`가 `POST https://rest.runpod.io/v1/pods`로 보내는 내용이다(필드명은 구축 시 API 문서로 확인).

```json
{
  "name": "voc-llm",
  "cloudType": "SECURE",
  "gpuCount": 1,
  "gpuTypeIds": ["NVIDIA A40", "NVIDIA RTX A6000", "NVIDIA L40",
                 "NVIDIA RTX PRO 5000 Blackwell", "NVIDIA L40S", "NVIDIA RTX 6000 Ada Generation"],
  "gpuTypePriority": "custom",
  "imageName": "vllm/vllm-openai:v0.33.0",
  "containerDiskInGb": 40,
  "ports": ["8000/http"],
  "env": {
    "HF_HOME": "/root/.cache/huggingface",
    "HF_TOKEN": "<HF_TOKEN>",
    "VLLM_API_KEY": "<VLLM_API_KEY>"
  },
  "dockerStartCmd": [
    "--model", "<MODEL_ID>",
    "--served-model-name", "voc-llm",
    "--host", "0.0.0.0", "--port", "8000",
    "--max-model-len", "32768",
    "--gpu-memory-utilization", "0.90",
    "--kv-cache-dtype", "auto"
  ]
}
```

- 볼륨 없이 컨테이너 디스크 40GB에 모델 1개(약 18GB)를 받는다.
- `VLLM_API_KEY` 환경변수가 설정되어 있으면 vLLM이 모든 요청에 Bearer 키를 요구한다. proxy URL이 공개되어 있어도 키 없이는 호출할 수 없다.
- `--max-model-len 32768`은 VOC 1건과 지침을 넣기에 충분한 값이다. 4bit 모델은 가중치가 약 15~20GB라서 48GB에서 남는 메모리가 KV cache로 간다.
- Qwen3.8-27B는 비전-언어 모델이다. 텍스트만 쓰면 `--limit-mm-per-prompt '{"image":0}'`를 추가해서 비전 처리 메모리를 줄인다.

## 5. 모델 후보

| 모델 | 구조 | 예상 VRAM(가중치) | HF repo |
|---|---|---|---|
| Gemma 4 26B A4B QAT-Q4 | MoE, 활성 4B | 약 15GB | `cyankiwi/gemma-4-26B-A4B-it-qat-AWQ-INT4` (공식 qat-w4a16-ct repo는 공개되어 있지 않다. 31B와 같은 QAT 기반이라 공정한 비교가 된다) |
| Gemma 4 31B QAT-Q4 | Dense | 약 18GB | `google/gemma-4-31B-it-qat-w4a16-ct` |
| Qwen3.6-35B-A3B AWQ-4bit | MoE, 활성 3B | 약 20GB | `QuantTrio/Qwen3.6-35B-A3B-AWQ` |
| Qwen3.8-27B AWQ-4bit | Dense VLM | 약 17GB | `cyankiwi/Qwen3.8-27B-AWQ-INT4` |

- "QAT-Q4" GGUF(Q4_0)는 llama.cpp용이라 사용하지 않는다. 같은 QAT 가중치의 vLLM 형식(w4a16-ct)을 쓴다.
- MoE 2종(26B A4B, 35B A3B)은 활성 파라미터가 작아서 토큰 속도가 Dense보다 빠를 것으로 예상된다. Dense 2종은 품질이 우세할 가능성이 있다.

### 5.1 선정 방법

1. 고객사가 마스킹한 실제 VOC 샘플 30~50건을 준비한다. 과업(분류, 요약, 답변 초안)별로 고르게 넣는다.
2. 4개 모델을 같은 GPU(A40), 같은 프롬프트, 같은 `max-model-len`, temperature 0으로 실행한다.
3. 측정 항목:
   - 응답 품질 (담당자 블라인드 평가)
   - 한국어 오류율
   - 첫 토큰 지연
   - 출력 토큰/초
   - 기동 소요시간 (START 로그의 `ready_sec`)
4. 품질이 동률이면 기동 시간이 짧고 처리 속도가 빠른 모델을 고른다. 선정 결과는 `.env`의 `MODEL_ID` 하나로 반영된다.

## 6. 보안

- Pod에는 SSH 포트와 Jupyter를 열지 않는다. `ports`에는 `8000/http`만 둔다.
- 요청과 응답 본문은 vLLM에서 로그로 남기지 않는다(기본 설정에서 본문을 기록하지 않음. `--enable-log-requests`를 켜지 않는다).
- Pod는 매일 삭제하므로 컨테이너 디스크에 남은 데이터는 그날로 사라진다.

## 7. 구축 시 기록 / 검증 체크리스트

| 항목 | 값 / 결과 |
|---|---|
| vLLM 이미지 태그 | `vllm/vllm-openai:v0.33.0` |
| 확정 모델 repo 4종 | `google/gemma-4-31B-it-qat-w4a16-ct`, `cyankiwi/gemma-4-26B-A4B-it-qat-AWQ-INT4`, `QuantTrio/Qwen3.6-35B-A3B-AWQ`, `cyankiwi/Qwen3.8-27B-AWQ-INT4` (`runpod/models.txt`) |

GPU별 검증 항목 (확보할 수 있는 GPU부터 진행):
1. Pod가 기동되고 `/v1/models`가 200을 준다.
2. `/v1/chat/completions` 스트리밍과 비스트리밍이 모두 정상 응답한다.
3. 5.1의 샘플 5건을 돌려서 A40 결과와 비교한다. temperature 0 기준으로 결과가 크게 다르지 않아야 한다.
4. `ready_sec`가 15분 제한 안에 들어온다(실측 약 4분).
