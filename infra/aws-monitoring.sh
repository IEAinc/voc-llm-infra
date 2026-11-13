#!/usr/bin/env bash
# 관리자 PC 에서 실행. 재실행하면 알람/규칙을 같은 이름으로 덮어쓴다.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./aws.env; . ./aws.out; set +a
# 운영은 VOC 전용 사용자(aws-voc-user.sh)로 한다. OPS_PROFILE 로 바꿀 수 있다
export AWS_DEFAULT_REGION=$REGION AWS_PROFILE=${OPS_PROFILE:-voc-llm} MSYS_NO_PATHCONV=1
jq() { command jq "$@" | tr -d "\015"; }   # Windows jq.exe 의 CRLF 출력 제거
IID=$INSTANCE_ID
TOPIC=$TOPIC_ARN
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 이미 확인된 구독이면 건너뛴다 (확인 메일 중복 방지). 확인 대기 중이면 메일을 다시 보낸다
subscribe_once() {  # subscribe_once REGION TOPIC_ARN
  local n
  n=$(aws sns list-subscriptions-by-topic --region "$1" --topic-arn "$2"     --query "length(Subscriptions[?Endpoint=='$ALERT_EMAIL' && SubscriptionArn!='PendingConfirmation'])" --output text)
  [ "$n" != 0 ] || aws sns subscribe --region "$1" --topic-arn "$2" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
}

# 1) SNS: 메일 구독, EventBridge 발행 허용
subscribe_once "$REGION" "$TOPIC"
aws sns set-topic-attributes --topic-arn "$TOPIC" --attribute-name Policy --attribute-value "$(jq -nc --arg t "$TOPIC" --arg a "$ACCOUNT" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "owner", Effect: "Allow", Principal: {AWS: "*"}, Action: ["SNS:Publish","SNS:Subscribe","SNS:GetTopicAttributes","SNS:SetTopicAttributes"],
     Resource: $t, Condition: {StringEquals: {"AWS:SourceOwner": $a}}},
    {Sid: "events", Effect: "Allow", Principal: {Service: "events.amazonaws.com"}, Action: "sns:Publish", Resource: $t}
  ]}')"

# us-east-1 토픽 (Route 53 health check 알람 전용)
TOPIC_USE1=$(aws sns create-topic --region us-east-1 --name voc-llm-alerts --query TopicArn --output text)
subscribe_once us-east-1 "$TOPIC_USE1"

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

echo "완료. 확인 대기 중인 구독이 있으면 $ALERT_EMAIL 로 간 확인 메일의 링크를 눌러야 알림이 옵니다."
