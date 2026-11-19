#!/usr/bin/env bash
# 평일 18:05 cron. 그날 EC2/Pod 가동 기록을 SNS 로 보낸다. .env 의 DAILY_REPORT_UNTIL(YYYY-MM-DD)까지만 보낸다.
# 메시지 속성 report=daily 를 붙인다. 받지 않을 구독에는 필터 정책 {"report":[{"exists":false}]} 을 건다.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
[ -n "${DAILY_REPORT_UNTIL:-}" ] && [[ ! "$(today)" > "$DAILY_REPORT_UNTIL" ]] || exit 0
[ -n "${SNS_TOPIC_ARN:-}" ] || exit 0

day=$(today)
prev=$(journalctl --list-boots --no-pager 2>/dev/null | awk '$1 == -1 {print $8, $9}')
msg="VOC LLM 가동 기록 $day

[EC2]
켜짐: $(uptime -s)
꺼짐 예정: 18:10 (직전 꺼짐: ${prev:-기록 없음})

[RunPod]
$(daily_pod_lines "$day")"

aws sns publish --region "${SNS_REGION:-ap-northeast-2}" --topic-arn "$SNS_TOPIC_ARN" \
  --subject "[voc-llm] Daily uptime $day" --message "$msg" \
  --message-attributes '{"report":{"DataType":"String","StringValue":"daily"}}' >/dev/null
