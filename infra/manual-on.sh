#!/usr/bin/env bash
# 수동 모드 켜기 (주말·야간 작업용). 관리자 PC 에서 실행: bash infra/manual-on.sh
#   EC2 가 꺼져 있으면 켜고, Pod 를 띄운 뒤 자동 종료(18:00 Pod, 18:10/19:30 EC2)를 멈춘다.
#   자동 종료 시각마다 "Auto shutdown skipped (manual mode)" 알림이 간다.
#   작업이 끝나면 반드시 infra/manual-off.sh 를 실행한다.
# 필요: aws.env/aws.out, voc-llm-key.pem, 이 PC 의 IP 가 보안그룹 22번에 허용돼 있을 것
# 사무실 밖 PC 는 먼저 22번 IP 허용 필요 (안 하면 SSH 에서 멈춤): docs/운영-가이드.md "실행 전 IP 허용 확인"
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; . ./aws.out; set +a
export AWS_DEFAULT_REGION=$REGION AWS_PROFILE MSYS_NO_PATHCONV=1
SSH=(ssh -i ./voc-llm-key.pem -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ubuntu@$EIP")

st=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text | tr -d '\r')
echo "EC2: $st"
if [ "$st" = stopping ]; then aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"; st=stopped; fi
if [ "$st" = stopped ]; then
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  echo "EC2 켜짐. SSH 대기"
fi
for i in $(seq 1 30); do "${SSH[@]}" true 2>/dev/null && break; sleep 5; done

echo "Pod 기동 중 (3~15분)"
"${SSH[@]}" 'sudo /opt/voc-llm/bin/voc-ctl.sh manual; sudo /opt/voc-llm/bin/voc-ctl.sh status'
