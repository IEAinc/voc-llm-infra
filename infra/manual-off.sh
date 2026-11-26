#!/usr/bin/env bash
# 수동 모드 끄기. 관리자 PC 에서 실행: bash infra/manual-off.sh
#   자동 종료를 되살린다. 업무시간(평일 08:30~17:59) 밖이면 바로 Pod 를 내리고 EC2 를 끈다.
#   업무시간이면 Pod 를 그대로 두고 18:00/18:10 에 평소처럼 꺼진다.
#   Pod 삭제에 실패하면 EC2 를 끄지 않고 "EC2 shutdown skipped" 알림을 보낸다.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; . ./aws.out; set +a
export AWS_DEFAULT_REGION=$REGION AWS_PROFILE MSYS_NO_PATHCONV=1
SSH=(ssh -i ./voc-llm-key.pem -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ubuntu@$EIP")

st=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text | tr -d '\r')
[ "$st" = running ] || { echo "EC2 가 $st 상태입니다. 끌 것이 없습니다."; exit 0; }
"${SSH[@]}" 'sudo /opt/voc-llm/bin/voc-ctl.sh status; sudo /opt/voc-llm/bin/voc-ctl.sh auto'
