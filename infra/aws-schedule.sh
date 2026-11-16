#!/usr/bin/env bash
# EC2 평일 자동 시작 스케줄과 EC2 가 스스로 감시를 끄고 켜는 권한. 관리자 프로필(aws.env 의 AWS_PROFILE)로 실행.
# 재실행하면 같은 이름으로 덮어쓴다. 종료는 EC2 의 cron(18:10 voc-ctl.sh shutdown)이 한다.
#   시작: EventBridge Scheduler voc-llm-ec2-start, 평일 08:30 (Asia/Seoul)
#   EC2 역할 voc-llm-ec2 에 추가: voc-llm 알람 알림 켜기/끄기, Route 53 health check 켜기/끄기
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; . ./aws.out; set +a
export AWS_DEFAULT_REGION=$REGION AWS_PROFILE MSYS_NO_PATHCONV=1
ACCT=$(aws sts get-caller-identity --query Account --output text)
HC=$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='$DOMAIN'].Id | [0]" --output text | tr -d '\r')
[ "$HC" != None ] || { echo "health check 가 없습니다. aws-monitoring.sh 를 먼저 실행하세요." >&2; exit 1; }

# 1) EC2 역할: 꺼지기 전 감시 끄기, 켜진 뒤 감시 켜기
aws iam put-role-policy --role-name voc-llm-ec2 --policy-name monitor-toggle --policy-document "$(cat <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "cloudwatch:DescribeAlarms", "Resource": "*"},
  {"Effect": "Allow", "Action": ["cloudwatch:EnableAlarmActions", "cloudwatch:DisableAlarmActions"],
   "Resource": "arn:aws:cloudwatch:*:$ACCT:alarm:voc-llm-*"},
  {"Effect": "Allow", "Action": "route53:UpdateHealthCheck", "Resource": "arn:aws:route53:::healthcheck/$HC"}
]}
EOF
)"

# 2) Scheduler 가 EC2 를 켤 역할
if ! aws iam get-role --role-name voc-llm-scheduler >/dev/null 2>&1; then
  aws iam create-role --role-name voc-llm-scheduler --tags Key=Project,Value=voc-llm --assume-role-policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"scheduler.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$ACCT\"}}}]}" >/dev/null
  sleep 10   # IAM 전파 대기
fi
aws iam put-role-policy --role-name voc-llm-scheduler --policy-name ec2-start --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ec2:StartInstances\",\"Resource\":\"arn:aws:ec2:$REGION:$ACCT:instance/$INSTANCE_ID\"}]}"
ROLE_ARN="arn:aws:iam::$ACCT:role/voc-llm-scheduler"

# 3) 평일 08:30 시작
ARGS=(--name voc-llm-ec2-start --schedule-expression "cron(30 8 ? * MON-FRI *)" --schedule-expression-timezone Asia/Seoul
  --flexible-time-window Mode=OFF --state ENABLED
  --target "{\"Arn\":\"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",\"RoleArn\":\"$ROLE_ARN\",\"Input\":\"{\\\"InstanceIds\\\":[\\\"$INSTANCE_ID\\\"]}\"}")
if aws scheduler get-schedule --name voc-llm-ec2-start >/dev/null 2>&1; then aws scheduler update-schedule "${ARGS[@]}" >/dev/null
else aws scheduler create-schedule "${ARGS[@]}" >/dev/null; fi

echo "완료: 평일 08:30 EC2 시작 스케줄(voc-llm-ec2-start), health check $HC"
echo "EC2 의 /opt/voc-llm/.env 에 HEALTH_CHECK_ID=$HC 가 있어야 밤사이 알람이 꺼집니다."
