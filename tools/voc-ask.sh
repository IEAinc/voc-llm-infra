#!/usr/bin/env bash
# curl 로 VOC LLM 에 질문한다. 한글이 깨지지 않도록 본문을 stdin(UTF-8)으로 보낸다.
#   export VOC_KEY=<고객사키>            # 필수
#   export VOC_URL=https://<도메인>      # 생략 시 아래 기본값
#   bash tools/voc-ask.sh "질문"                    # 답변만 출력
#   bash tools/voc-ask.sh -s "시스템 프롬프트" "질문"
#   VOC_STREAM=1 bash tools/voc-ask.sh "질문"       # 스트리밍 원문(SSE)
#   VOC_RAW=1 bash tools/voc-ask.sh "질문"          # 응답 JSON 원문
set -euo pipefail
: "${VOC_KEY:?VOC_KEY(고객사 키)를 설정하세요}"
URL="${VOC_URL:-https://43-200-20-252.sslip.io}"
sys=""
if [ "${1:-}" = -s ]; then sys=$2; shift 2; fi
[ $# -ge 1 ] || { echo "사용법: $0 [-s 시스템프롬프트] 질문" >&2; exit 2; }

esc() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}; printf '%s' "${s//$'\n'/\\n}"; }
msgs="{\"role\":\"user\",\"content\":\"$(esc "$1")\"}"
[ -n "$sys" ] && msgs="{\"role\":\"system\",\"content\":\"$(esc "$sys")\"},$msgs"
stream=false; [ -n "${VOC_STREAM:-}" ] && stream=true
body="{\"model\":\"voc-llm\",\"temperature\":0,\"max_tokens\":${VOC_MAX_TOKENS:-800},\"stream\":$stream,\"messages\":[$msgs]}"

if [ "$stream" = true ] || [ -n "${VOC_RAW:-}" ]; then
  printf '%s' "$body" | curl -sSN "$URL/v1/chat/completions" -H "Authorization: Bearer $VOC_KEY" \
    -H 'Content-Type: application/json; charset=utf-8' --data-binary @-
  echo
  exit
fi
resp=$(printf '%s' "$body" | curl -sS "$URL/v1/chat/completions" -H "Authorization: Bearer $VOC_KEY" \
  -H 'Content-Type: application/json; charset=utf-8' --data-binary @- -w '\n%{http_code}')
code=${resp##*$'\n'}; resp=${resp%$'\n'*}
if [ "$code" != 200 ]; then echo "HTTP $code: $resp" >&2; exit 1; fi
if command -v jq >/dev/null; then jq -r '.choices[0].message.content' <<<"$resp" | tr -d '\r'
else py -3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" <<<"$resp" 2>/dev/null \
  || python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" <<<"$resp"; fi
