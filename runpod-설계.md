# RunPod LLM 서버 설계

## 1. 계정과 키

| 항목 | 설정 |
|---|---|
| 클라우드 | **Secure Cloud만** 사용한다 (Community는 테스트에서도 VOC 데이터를 넣지 않는다) |
| RunPod API 키 | 권한을 최소로 둔 키 1개 발급. AWS `/opt/voc-llm/.env`에만 보관한다 |
| HF 토큰 | read 권한. Gemma 계열 라이선스 동의 계정으로 발급한다 |
| vLLM 내부 키 | 무작위 32바이트 이상 (`VLLM_API_KEY`). AWS nginx만 알고 있다 |
| 결제 | 잔액 부족으로 Pod 생성이 실패하지 않도록 자동 충전을 켜고 최소 잔액 알림을 설정한다 |

## 2. Network Volume

| 항목 | 값 |
|---|---|
| 크기 | 100GB (후보 4종 × 약 15~22GB와 여유분) |
| 비용 | $0.07/GB/월 = 약 $7/월 (Pod 유무와 관계없이 과금) |
| 마운트 경로 | `/workspace` |
| 내용 | `/workspace/hf` = Hugging Face 캐시 (`HF_HOME`) |

### 2.1 데이터센터 선택 (가장 중요)

Network Volume은 **데이터센터 1곳에 묶이고**, 볼륨을 붙인 Pod는 그 데이터센터에서만 뜬다.
그러므로 GPU 6종 중 **가능한 많은 종류를 제공하는 Secure 데이터센터**를 골라야 한다.

선택 절차:
1. RunPod 콘솔의 Network Volume 생성 화면에서 데이터센터별 GPU 목록을 확인한다. API로는 `GET /v1/datacenters`로 확인한다.
2. RTX A6000과 A40이 **둘 다 있는** 데이터센터를 우선한다. 이 둘이 1, 2순위이고 단가가 $0.59로 같다.
3. 남은 후보 중 L40, RTX 6000 Ada, L40S가 많은 곳을 고른다.
4. 선정 결과(데이터센터 ID와 제공 GPU 목록)를 이 문서의 7장에 기록한다.

선택한 데이터센터에 6종이 모두 없거나 일시적으로 품절이면, AWS `pod-start.sh`의 2단계가 볼륨 없이 다른 데이터센터에 Pod를 띄운다.
이때 모델은 HF에서 새로 받는다.

### 2.2 모델 사전 다운로드 (최초 1회)

볼륨을 붙인 가장 저렴한 Pod(CPU Pod도 가능)를 잠깐 띄워서 후보 모델을 모두 받아둔다.

```bash
export HF_HOME=/workspace/hf
pip install -U "huggingface_hub[cli]"
huggingface-cli login --token $HF_TOKEN
for m in \
  google/gemma-4-26B-A4B-it-qat-w4a16-ct \
  google/gemma-4-31B-it-qat-w4a16-ct \
  <Qwen3.6-35B-A3B AWQ repo> \
  <Qwen3.8-27B AWQ repo> ; do
  huggingface-cli download "$m"
done
du -sh /workspace/hf
```

Qwen 계열 AWQ는 공식 저장소가 아닐 수 있다. 구축할 때 아래 기준으로 repo를 고르고 5장 표에 확정 기록한다.
- 다운로드 수
- 작성자 신뢰도 (Qwen 공식, RedHatAI, 그 외 검증된 양자화 작성자)
- vLLM 동작 확인 여부

## 3. GPU 우선순위와 호환성

| 순위 | GPU | 아키텍처 (SM) | 단가 | 비고 |
|---|---|---|---|---|
| 1 | RTX A6000 48GB | Ampere (8.6) | $0.59 | 기준 GPU |
| 2 | A40 48GB | Ampere (8.6) | $0.59 | A6000과 사실상 같은 성능 |
| 3 | L40 48GB | Ada (8.9) | $0.82 | |
| 4 | RTX 6000 Ada 48GB | Ada (8.9) | $0.99 | |
| 5 | L40S 48GB | Ada (8.9) | $1.09 | |
| 6 | RTX PRO 6000 MIG 48GB | Blackwell (12.0) | $1.29 | 96GB GPU를 MIG로 분할한 48GB. SM 수가 절반이라 처리량이 전체 GPU보다 낮다 |

호환성 원칙:
- **CUDA 12.8 이상 vLLM 이미지**를 쓴다. 이 이미지는 Ampere부터 Blackwell까지 6종 모두를 지원한다. 이미지 태그는 버전을 고정한다(예: `vllm/vllm-openai:v0.x.y`, 구축 시 최신 안정판으로 확정). `latest`는 쓰지 않는다.
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
  "gpuTypeIds": ["NVIDIA RTX A6000", "NVIDIA A40", "NVIDIA L40",
                 "NVIDIA RTX 6000 Ada Generation", "NVIDIA L40S", "<PRO 6000 MIG 48GB ID>"],
  "gpuTypePriority": "custom",
  "imageName": "vllm/vllm-openai:<고정 버전>",
  "networkVolumeId": "<NETWORK_VOLUME_ID>",
  "volumeMountPath": "/workspace",
  "containerDiskInGb": 40,
  "ports": ["8000/http"],
  "env": {
    "HF_HOME": "/workspace/hf",
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

- 2단계(볼륨 없음)에서는 `networkVolumeId`와 `volumeMountPath`를 빼고 `HF_HOME`을 `/root/.cache/huggingface`로 둔다. 컨테이너 디스크 40GB에 모델 1개를 받는다.
- `VLLM_API_KEY` 환경변수가 설정되어 있으면 vLLM이 모든 요청에 Bearer 키를 요구한다. proxy URL이 공개되어 있어도 키 없이는 호출할 수 없다.
- `--max-model-len 32768`은 VOC 1건과 지침을 넣기에 충분한 값이다. 4bit 모델은 가중치가 약 15~20GB라서 48GB에서 남는 메모리가 KV cache로 간다.
- Qwen3.8-27B는 비전-언어 모델이다. 텍스트만 쓰면 `--limit-mm-per-prompt '{"image":0}'`를 추가해서 비전 처리 메모리를 줄인다.

## 5. 모델 후보

| 모델 | 구조 | 예상 VRAM(가중치) | HF repo (구축 시 확정) |
|---|---|---|---|
| Gemma 4 26B A4B QAT-Q4 | MoE, 활성 4B | 약 15GB | `google/gemma-4-26B-A4B-it-qat-w4a16-ct` (존재 여부 확인, 없으면 커뮤니티 AWQ 사용) |
| Gemma 4 31B QAT-Q4 | Dense | 약 18GB | `google/gemma-4-31B-it-qat-w4a16-ct` |
| Qwen3.6-35B-A3B AWQ-4bit | MoE, 활성 3B | 약 20GB | 확정 필요 |
| Qwen3.8-27B AWQ-4bit | Dense VLM | 약 17GB | 확정 필요 |

- "QAT-Q4" GGUF(Q4_0)는 llama.cpp용이라 사용하지 않는다. 같은 QAT 가중치의 vLLM 형식(w4a16-ct)을 쓴다.
- MoE 2종(26B A4B, 35B A3B)은 활성 파라미터가 작아서 토큰 속도가 Dense보다 빠를 것으로 예상된다. Dense 2종은 품질이 우세할 가능성이 있다.

### 5.1 선정 방법

1. 고객사가 마스킹한 실제 VOC 샘플 30~50건을 준비한다. 과업(분류, 요약, 답변 초안)별로 고르게 넣는다.
2. 4개 모델을 같은 GPU(A6000), 같은 프롬프트, 같은 `max-model-len`, temperature 0으로 실행한다.
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
- Network Volume에는 모델 파일만 둔다. VOC 데이터는 저장하지 않는다.
- Pod는 매일 삭제하므로 컨테이너 디스크에 남은 데이터는 그날로 사라진다.

## 7. 구축 시 기록 / 검증 체크리스트

| 항목 | 값 / 결과 |
|---|---|
| Network Volume 데이터센터 ID | |
| 해당 데이터센터 제공 GPU (6종 중) | |
| PRO 6000 MIG 48GB의 gpuTypeId | |
| vLLM 이미지 태그 | |
| 확정 모델 repo 4종 | |

GPU별 검증 항목 (확보할 수 있는 GPU부터 진행):
1. Pod가 기동되고 `/v1/models`가 200을 준다.
2. `/v1/chat/completions` 스트리밍과 비스트리밍이 모두 정상 응답한다.
3. 5.1의 샘플 5건을 돌려서 A6000 결과와 비교한다. temperature 0 기준으로 결과가 크게 다르지 않아야 한다.
4. `ready_sec`가 25분 제한 안에 들어온다. 2단계(볼륨 없음)에서도 확인한다.
